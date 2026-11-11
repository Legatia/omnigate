defmodule OmnigateControl.Wave6Test.Stub do
  @moduledoc """
  A provider and a webhook receiver that misbehave on request: error bodies
  that are not text, answers far larger than anyone asked for, slow answers.
  """
  use Plug.Router

  @table :omnigate_wave6_stub

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"], length: 8_000_000)
  plug(:dispatch)

  def setup do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    :ets.delete_all_objects(@table)
  end

  def set(key, value), do: :ets.insert(@table, {key, value})

  def val(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{_, v}] -> v
      [] -> default
    end
  end

  def bump(name, by \\ 1), do: :ets.update_counter(@table, name, by, {name, 0})

  # Remembers every value seen, so the largest can be read without a race.
  defp observe(name, value), do: bump({:observed, name, value})

  def max(name) do
    @table |> :ets.match({{:observed, name, :"$1"}, :_}) |> List.flatten() |> Enum.max(fn -> 0 end)
  end

  # Bytes no text encoding accepts, and a line break with something that
  # looks like a log line after it.
  def garbage, do: <<"Bad Gateway caf", 0xE9, " ", 0xFF, "\n12:00:00.000 [error] forged line">>

  post "/v1/models/:owner/:name/predictions" do
    bump(:submits)
    set(:last_input, conn.body_params["input"])

    case val(:submit, :ok) do
      :ok ->
        body = %{id: "p-#{System.unique_integer([:positive])}", status: "succeeded", output: "http://127.0.0.1:#{conn.port}/files/out.png"}
        conn |> put_resp_content_type("application/json") |> send_resp(201, JSON.encode!(body))

      :garbage ->
        send_resp(conn, 502, garbage())
    end
  end

  get "/files/:name" do
    conn |> put_resp_header("content-type", "image/png") |> send_resp(200, "PNG-" <> name)
  end

  # An image provider of the OpenAI kind: answers at once, with the file inline.
  post "/v1/images/generations" do
    bump(:submits)
    conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(%{data: [%{b64_json: Base.encode64("PNG-inline")}]}))
  end

  # Answers 200 with five megabytes nobody will read.
  post "/hook/big" do
    bump(:hooks)
    send_resp(conn, 200, :binary.copy("x", 5 * 1024 * 1024))
  end

  # Looks at what the job record says while its own delivery is in flight.
  post "/hook/peek" do
    bump(:hooks)
    id = conn.body_params["data"]["id"]
    set({:seen, id}, OmnigateControl.Jobs.Store.get(id)["webhook"])
    send_resp(conn, 200, "ok")
  end

  # Slow, and counts how many deliveries are in flight at once: for one key and overall.
  post "/hook/slow/:key" do
    observe({:key, key}, bump({:now, key}))
    observe(:overall, bump(:now_overall))
    Process.sleep(120)
    bump({:now, key}, -1)
    bump(:now_overall, -1)
    bump(:hooks)
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule OmnigateControl.Wave6Test do
  @moduledoc """
  The second security review, control-plane side: one regression test (at
  least) per finding. See the section headers for which is which.
  """
  # Not async: jobs, keys, the ledger, the audit log and the config are shared named processes.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias OmnigateControl.{AdminAuth, Audit, ConfigStore, Counters, Errors, Http, Jobs, Keys, Ledger, RateLimit, Router, Text, Webhooks}
  alias OmnigateControl.Jobs.{Adapter, Store}
  alias OmnigateControl.Ledger.{Files, Ids}
  alias OmnigateControl.Wave6Test.Stub

  @admin "test-admin-token-0123456789"
  @day_ms 86_400_000

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Stub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("OMNIGATE_TEST_PROVIDER_KEY", "provider-secret")
    # Owned by this (module-long) process, so a request that arrives after a test ended still finds it.
    Stub.setup()
    original = ConfigStore.get().media
    on_exit(fn -> ConfigStore.put_media(original) end)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  setup %{base: base} do
    wait_idle()
    Stub.setup()
    ConfigStore.put_media(media(base))
    dir = Path.join(System.tmp_dir!(), "omnigate-w6-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # -- helpers ---------------------------------------------------------------

  defp media(base, opts \\ []) do
    price = Keyword.get(opts, :price, %{per_job_usd: 0.0, per_output_usd: 0.25, per_input_char_usd: 0.0, per_second_usd: 0.0})
    target = Map.merge(%{upstream: "prov", model: "owner/model", price: price}, Keyword.get(opts, :target, %{}))
    route = Map.merge(%{model: "w6", cache_ttl_s: nil, timeout_s: 30, targets: [target]}, Keyword.get(opts, :route, %{}))

    %{
      public_base_url: "http://gateway.test",
      poll_interval_ms: 10,
      max_output_bytes: 1_000_000,
      max_input_bytes: 1_048_576,
      max_open_jobs: 100,
      upstreams: [%{name: "prov", kind: "replicate", base_url: base, api_key_env: "OMNIGATE_TEST_PROVIDER_KEY"}],
      routes: [route],
      storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600},
      webhooks: Map.merge(%{retry_schedule_ms: [30], max_attempts: 2, timeout_ms: 2_000, allow_private: true, secret: "s"}, Keyword.get(opts, :webhooks, %{}))
    }
  end

  defp wait_idle(tries \\ 500) do
    busy = Enum.reject(Store.all(), &Jobs.terminal?/1)

    cond do
      busy == [] -> :ok
      tries == 0 -> Enum.each(busy, &Jobs.finish(&1["id"], "canceled", %{}))
      true -> Process.sleep(10) && wait_idle(tries - 1)
    end
  end

  defp await(id, pred \\ &Jobs.terminal?/1, tries \\ 500) do
    job = Store.get(id)

    cond do
      pred.(job) -> job
      tries == 0 -> flunk("timed out waiting for job #{id}: #{inspect(job)}")
      true -> Process.sleep(10) && await(id, pred, tries - 1)
    end
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp unique, do: System.unique_integer([:positive])
  defp hash, do: "w6key-#{unique()}"
  defp job_id, do: "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  defp call(conn), do: Router.call(conn, Router.init([]))
  defp json(conn), do: JSON.decode!(conn.resp_body)
  defp with_headers(conn, headers), do: Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

  defp internal(conn, hash \\ nil),
    do: with_headers(conn, [{"x-omnigate-internal", OmnigateControl.internal_token()}] ++ if(hash, do: [{"x-omnigate-key-sha256", hash}], else: []))

  defp bearer(conn, token \\ @admin), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp post_job(hash, body, headers \\ []) do
    conn(:post, "/internal/v1/jobs", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> internal(hash)
    |> with_headers(headers)
    |> call()
  end

  defp managed_key(attrs) do
    name = "w6-#{unique()}"
    {:ok, key, _raw} = Keys.create(Map.put(attrs, "name", name))
    on_exit(fn -> Keys.delete(name) end)
    key
  end

  # A finished job whose webhook is due, put straight into the store.
  defp job_with_webhook(key_hash, url, webhook \\ %{}) do
    id = job_id()
    now = System.os_time(:millisecond)

    {:ok, _} =
      Store.create(%{
        "id" => id,
        "status" => "succeeded",
        "model" => "w6",
        "input" => %{"prompt" => "p"},
        "outputs" => [],
        "attempts" => [],
        "key_sha256" => key_hash,
        "created_ms" => now,
        "finished_ms" => now,
        "ledgered" => true,
        "webhook" => Map.merge(%{"url" => url, "status" => "pending", "attempts" => 0, "last_status" => nil, "next_attempt_ms" => now}, webhook)
      })

    id
  end

  # A one-connection TCP server that answers whatever it is sent with `head`
  # and then `megabytes` of body, and tells the test how much it managed to
  # send before the other side went away.
  defp serve(head, megabytes, opts \\ []) do
    test = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    chunk = :binary.copy(<<0>>, 1_048_576)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(test, {:request, request})
      :gen_tcp.send(socket, head)

      sent =
        Enum.reduce_while(1..max(megabytes, 1)//1, 0, fn _, sent ->
          data = if megabytes == 0, do: Keyword.get(opts, :body, ""), else: chunk
          if :gen_tcp.send(socket, data) == :ok, do: {:cont, sent + byte_size(data)}, else: {:halt, sent}
        end)

      if Keyword.get(opts, :hold, false), do: Process.sleep(2_000)
      :gen_tcp.close(socket)
      send(test, {:sent, sent})
    end)

    "http://127.0.0.1:#{port}"
  end

  # ============================================================= H3: response sizes

  describe "H3: every outbound response is read through a cap" do
    test "a webhook-sized read keeps the first KiB and drops the connection; nothing waits for the rest" do
      total = 64
      url = serve("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{total * 1_048_576}\r\nConnection: close\r\n\r\n", total)
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{status: 200, body: body, truncated: true}} =
               Http.request(:post, url <> "/hook", [], "{}", max_body: 16 * 1024, overflow: :truncate, timeout: 10_000)

      assert byte_size(body) == 16 * 1024
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert_receive {:sent, sent}, 10_000
      assert sent < total * 1_048_576
    end

    test "without :truncate an oversized answer is an error, and the default cap is a few MiB" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: #{64 * 1_048_576}\r\n\r\n", 64)
      assert {:error, :response_too_large} = Http.request(:get, url <> "/big", [])
      assert_receive {:sent, sent}, 10_000
      assert sent < 64 * 1_048_576

      # Chunked and until-close bodies have no declared length; the cap counts what arrives.
      chunked = serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", 0, body: "100000\r\n" <> :binary.copy("y", 1_048_576) <> "\r\n0\r\n\r\n")
      assert {:error, :response_too_large} = Http.request(:get, chunked, [], nil, max_body: 1000)
      assert_receive {:sent, _}, 10_000

      close = serve("HTTP/1.1 200 OK\r\n\r\n", 8)
      assert {:error, :response_too_large} = Http.request(:get, close, [], nil, max_body: 1000)
      assert_receive {:sent, _}, 10_000
    end

    test "a download reads no body at all unless the answer is a 200, whatever its size" do
      dest = Path.join(System.tmp_dir!(), "omnigate-w6-download-#{unique()}")
      url = serve("HTTP/1.1 404 Not Found\r\nContent-Length: #{64 * 1_048_576}\r\n\r\n", 64)
      started = System.monotonic_time(:millisecond)
      assert {:error, {:http_status, 404}} = Http.download(url <> "/out.png", dest, 1_048_576)
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert_receive {:sent, sent}, 10_000
      assert sent < 64 * 1_048_576
      refute File.exists?(dest)

      # A 200 is cut off at the limit, and what was written is removed.
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: #{8 * 1_048_576}\r\n\r\n", 8)
      assert {:error, :output_too_large} = Http.download(url <> "/out.png", dest, 1_048_576)
      assert_receive {:sent, _}, 10_000
      refute File.exists?(dest)
    end

    test "the client still speaks HTTP: lengths, chunks, close-delimited bodies, request bodies, headers" do
      url = serve("HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nX-Thing: a b\r\nContent-Length: 5\r\n\r\n", 0, body: "hello")

      assert {:ok, %{status: 201, body: "hello", truncated: false, headers: %{"content-type" => "text/plain", "x-thing" => "a b"}}} =
               Http.request(:post, url <> "/p?q=1", [{"x-a", "b"}], "{\"k\":1}")

      assert_receive {:request, request}
      assert request =~ ~r/\APOST \/p\?q=1 HTTP\/1\.1\r\n/
      assert request =~ "x-a: b\r\n" and request =~ "content-length: 7\r\n" and request =~ "connection: close\r\n"
      assert String.ends_with?(request, "\r\n\r\n{\"k\":1}")

      chunked = serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", 0, body: "3\r\nabc\r\n4;x=y\r\ndefg\r\n0\r\n\r\n")
      assert {:ok, %{status: 200, body: "abcdefg"}} = Http.request(:get, chunked, [])

      close = serve("HTTP/1.1 200 OK\r\n\r\n", 0, body: "until the end")
      assert {:ok, %{status: 200, body: "until the end"}} = Http.request(:get, close, [])

      # A body shorter than promised is an error, not a short answer.
      short = serve("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n", 0, body: "only this")
      assert {:error, :truncated_response} = Http.request(:get, short, [])

      # A 3xx is returned, not followed; a stalled peer is a timeout.
      redirect = serve("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\n\r\n", 0)
      assert {:ok, %{status: 302, headers: %{"location" => "http://127.0.0.1:1/"}}} = Http.request(:get, redirect, [])
      stalled = serve("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n", 0, body: "abc", hold: true)
      assert {:error, :timeout} = Http.request(:get, stalled, [], nil, timeout: 300)

      # Nothing that would start a new header line is ever sent.
      assert {:error, :invalid_header} = Http.request(:get, "http://127.0.0.1:1/", [{"x", "a\r\nevil: 1"}])
      assert {:error, :invalid_url} = Http.request(:get, "http://127.0.0.1:1/a b", [])
    end

    test "a webhook receiver answering megabytes is a delivered webhook, not a memory problem", %{base: base} do
      id = job_with_webhook(hash(), base <> "/hook/big")
      Webhooks.schedule(id, 0)
      job = await(id, &(&1["webhook"]["status"] == "delivered"))
      assert %{"attempts" => 1, "last_status" => 200} = job["webhook"]
      assert Stub.val(:hooks) == 1
    end

    test "an attempt is in the job record before the request is sent", %{base: base} do
      id = job_with_webhook(hash(), base <> "/hook/peek")
      Webhooks.schedule(id, 0)
      await(id, &(&1["webhook"]["status"] == "delivered"))

      # What the receiver saw in the store while its request was in flight.
      assert %{"attempts" => 1, "status" => "pending", "next_attempt_ms" => next} = Stub.val({:seen, id})
      assert next > System.os_time(:millisecond) - 5_000
      assert %{"attempts" => 1, "last_error" => nil, "last_status" => 200} = Store.get(id)["webhook"]
    end

    test "a delivery cut short over and over still ends after max_attempts, without another request", %{base: base} do
      # What a crash during the second (last) attempt leaves behind.
      id = job_with_webhook(hash(), base <> "/hook/peek", %{"status" => "retrying", "attempts" => 2, "last_error" => "interrupted"})
      log = capture_log(fn -> Webhooks.deliver(id) end)
      assert log =~ "gave up after 2 attempts"
      assert %{"status" => "failed", "attempts" => 2} = Store.get(id)["webhook"]
      assert Stub.val(:hooks, 0) == 0
    end

    test "deliveries are capped per key and overall, and everyone still gets theirs", %{base: base} do
      ConfigStore.put_media(media(base, webhooks: %{max_concurrent: 2, max_concurrent_per_key: 1}))
      keys = for _ <- 1..3, do: hash()
      ids = for key <- keys, _ <- 1..3, do: job_with_webhook(key, base <> "/hook/slow/" <> key)
      Enum.each(ids, &Webhooks.schedule(&1, 0))

      assert wait_until(fn -> Enum.all?(ids, &(Store.get(&1)["webhook"]["status"] == "delivered")) end, 1_000)
      for key <- keys, do: assert(Stub.max({:key, key}) == 1)
      assert Stub.max(:overall) == 2
      assert Stub.val(:hooks) == 9
      assert wait_until(fn -> match?(%{running: 0, waiting: 0}, Webhooks.status()) end)
    end

    test "the caps and the daily job limit have defaults and are validated" do
      media = ConfigStore.normalize(%{}).media
      assert %{max_concurrent: 16, max_concurrent_per_key: 4} = media.webhooks
      assert media.max_jobs_per_day == 10_000
      assert ConfigStore.normalize(%{"media" => %{"max_jobs_per_day" => 0, "webhooks" => %{"max_concurrent" => 3}}}).media.max_jobs_per_day == 0

      assert_raise ArgumentError, ~r/max_concurrent must be a whole number from 1/, fn ->
        ConfigStore.normalize(%{"media" => %{"webhooks" => %{"max_concurrent" => 0}}})
      end

      assert_raise ArgumentError, ~r/"max_jobs_per_day" must be a whole number/, fn -> ConfigStore.normalize(%{"media" => %{"max_jobs_per_day" => -1}}) end

      assert_raise ArgumentError, ~r/retry_schedule_ms must be a list/, fn ->
        ConfigStore.normalize(%{"media" => %{"webhooks" => %{"retry_schedule_ms" => [1, "soon"]}}})
      end
    end

    test "jobs that fail at once still count towards the key's jobs per day", %{base: base} do
      Stub.set(:submit, :garbage)
      key = managed_key(%{"max_jobs_per_day" => 2, "webhook_secret" => "whs"})
      body = %{"model" => "w6", "input" => %{"prompt" => "x"}, "webhook_url" => base <> "/hook/peek"}

      capture_log(fn ->
        ids = for _ <- 1..2, do: json(post_job(key.key_sha256, body))["id"]
        Enum.each(ids, &await/1)
        # Both are finished, so the open-jobs limit has nothing to say; the daily one does.
        assert Store.open_count([key.key_sha256]) == 0
        refused = post_job(key.key_sha256, body)
        assert refused.status == 429
        assert %{"error" => %{"code" => "too_many_jobs_today", "type" => "rate_limit_error"}} = json(refused)
        Enum.each(ids, &await(&1, fn job -> job["webhook"]["status"] == "delivered" end))
      end)

      assert Store.day_count([key.key_sha256]) == 2
      # Two jobs, two webhooks: the third request cost nothing.
      assert Stub.val(:hooks) == 2
      assert Stub.val(:submits) == 2
    end
  end

  # ============================================================= M3: text from outside

  describe "M3: bytes that are not text cannot stop a process" do
    test "Text makes anything storable and single-line" do
      assert Text.utf8(<<"caf", 0xE9>>) == "caf\uFFFD"
      assert Text.line("a\r\nb\tc\u2028d\x00e   f", 100) == "a b c d e f"
      assert String.valid?(Text.line(Stub.garbage()))
      refute Text.line(Stub.garbage()) =~ "\n"
      assert Text.line(String.duplicate("x", 500), 10) == "xxxxxxxxxx"
      assert Text.line({:tls, :closed}) == "{:tls, :closed}"

      dirty = %{"a" => [<<0xFF>>, %{<<0xFE>> => 1}], "t" => {:x, 1}, "n" => nil, "ok" => true}
      assert Text.dirty?(dirty)
      clean = Text.clean(dirty)
      refute Text.dirty?(clean)
      assert is_binary(JSON.encode!(clean))
      assert Text.clean(%{"same" => "text", "n" => 1.5}) == %{"same" => "text", "n" => 1.5}
    end

    test "a provider's error body is described as one valid line" do
      text = Adapter.describe({:ok, %{status: 502, body: Stub.garbage()}})
      assert String.valid?(text) and not String.contains?(text, "\n")
      assert text =~ "http_502: Bad Gateway caf"
      assert String.valid?(Adapter.describe({:error, {:failed, <<0xFF, 0xFE>>}}))
    end

    test "the job store keeps running whatever it is asked to write (the review's reproduction)" do
      store = Process.whereis(Store)
      outcome = <<"http_502: Bad Gateway caf", 0xE9, " ", 0xFF>>

      for i <- 1..4 do
        id = job_id()
        {:ok, _} = Store.create(%{"id" => id, "status" => "running", "key_sha256" => "w6-m3", "created_ms" => i, "attempts" => []})
        assert {:ok, job} = Store.update(id, fn j -> Map.put(j, "attempts", [%{"upstream" => "u", "outcome" => outcome}]) end)
        assert [%{"outcome" => stored}] = job["attempts"]
        assert String.valid?(stored) and stored =~ "Bad Gateway caf"
        assert {:ok, _} = Store.update(id, &Map.put(&1, "status", "failed"))
      end

      # An update function that raises is its caller's problem only.
      id = job_id()
      {:ok, _} = Store.create(%{"id" => id, "status" => "running", "key_sha256" => "w6-m3", "created_ms" => 9, <<"bad", 0xFF>> => <<0xFF>>})
      assert capture_log(fn -> assert {:error, :update_failed} = Store.update(id, fn _ -> raise "boom" end) end) =~ "boom"
      assert {:error, :update_failed} = Store.update(id, fn _ -> :not_a_job end)
      assert {:ok, _} = Store.update(id, &Map.put(&1, "status", "failed"))

      assert Process.whereis(Store) == store
      # Every line that reached the log can be read back.
      log = File.read!(Application.fetch_env!(:omnigate_control, :jobs_path))
      assert String.valid?(log)
    end

    test "a provider that answers with garbage fails the job, not the gateway; and cannot write log lines", %{base: _base} do
      Stub.set(:submit, :garbage)
      store = Process.whereis(Store)
      ledger = Process.whereis(Ledger)

      log =
        capture_log(fn ->
          for _ <- 1..4 do
            {:ok, job} = Jobs.create(hash(), %{"model" => "w6", "input" => %{"prompt" => "x"}})
            done = await(job["id"], &(&1["ledgered"] == true))
            assert done["status"] == "failed"
            assert [%{"upstream" => "prov", "outcome" => outcome}] = done["attempts"]
            assert String.valid?(outcome) and outcome =~ "http_502" and not String.contains?(outcome, "\n")
            assert done["ledgered"] == true
          end
        end)

      assert Process.whereis(Store) == store and Process.whereis(Ledger) == ledger
      # What the provider sent after its line break is part of our line, not a line of its own.
      assert log =~ "forged line"
      refute log =~ ~r/^12:00:00\.000 \[error\] forged line/m
    end

    test "X-Forwarded-For with bytes that are not text is recorded, four times over (the review's reproduction)" do
      audit = Process.whereis(Audit)
      peer = {10, 66, 0, unique() |> rem(250)}

      login = fn ->
        conn(:post, "/login", "password=nope")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-forwarded-for", <<"203.0.113.9, ", 0xFF, "\nforged">>)
        |> Map.put(:remote_ip, peer)
        |> call()
      end

      for _ <- 1..4, do: assert(login.().status == 401)
      assert Process.whereis(Audit) == audit
      address = peer |> :inet.ntoa() |> to_string()
      assert [%{"forwarded_for" => forwarded, "outcome" => "denied"}] = Enum.filter(Audit.recent(50), &(&1["address"] == address))
      assert String.valid?(forwarded) and forwarded =~ "203.0.113.9" and not String.contains?(forwarded, "\n")

      # The same through an authenticated action, which waits for its entry.
      conn = conn(:post, "/x") |> put_req_header("x-forwarded-for", <<0xFF, 0xFE>>)
      assert :ok = Audit.record(conn, "key.create", <<"name", 0xFF>>, "ok", auth: "token")
      assert [%{"target" => target} | _] = Audit.recent(1)
      assert String.valid?(target)
      assert Process.whereis(Audit) == audit
    end

    test "a usage event with text that is not UTF-8 is kept, repaired; a malformed one is counted, not fatal" do
      ledger = Process.whereis(Ledger)
      key = hash()
      invalid_before = Counters.get(:ledger_invalid_events)

      log =
        capture_log(fn ->
          assert {:ok, %{accepted: 1, invalid: 0}} =
                   Ledger.record_media(%{
                     "id" => "w6-#{unique()}",
                     "key_sha256" => key,
                     "status" => 502,
                     "cost_usd" => 0.5,
                     "attempts" => [%{"outcome" => <<0xFF>>}]
                   })

          assert {:ok, %{accepted: 0, invalid: 3}} =
                   Ledger.record_batch([
                     %{"key_sha256" => key},
                     %{"key_sha256" => key, "status" => 200, "input_tokens" => -1},
                     %{"key_sha256" => key, "status" => 200, "input_tokens" => 10 ** 40}
                   ])

          # Times and costs no calendar or float can hold are not worth a crash either.
          assert {:ok, %{accepted: 2}} =
                   Ledger.record_batch([
                     %{"key_sha256" => key, "status" => 200, "ts_ms" => 10 ** 30},
                     %{"key_sha256" => key, "status" => 200, "ts_ms" => -5}
                   ])
        end)

      assert log =~ "dropped 3 of 3 usage events"
      assert Counters.get(:ledger_invalid_events) == invalid_before + 3
      assert Ledger.totals(key).requests == 3
      assert Ledger.spend(key) == 0.5
      assert Process.whereis(Ledger) == ledger
      assert {200, body} = metrics()
      assert body =~ ~r/^omnigate_ledger_invalid_events_total \d+$/m
    end

    test "a group of processes that keeps crashing is restarted with a pause, by a guard that does not crash", %{dir: dir} do
      marker = Path.join(dir, "starts")
      test = self()

      crasher = %{
        id: :crasher,
        start:
          {Task, :start_link,
           [
             fn ->
               File.write!(marker, "x", [:append])
               send(test, :started)
               Process.sleep(if(File.stat!(marker).size > 6, do: :infinity, else: 5))
               exit(:boom)
             end
           ]},
        restart: :permanent
      }

      capture_log(fn ->
        {:ok, guard} = OmnigateControl.Guard.start_link(name: :"w6_guard_#{unique()}", supervisor_name: :"w6_group_#{unique()}", children: [crasher])
        first = OmnigateControl.Guard.supervisor(guard)
        # Four crashes in a row finish the supervisor (3 restarts in 5 s)...
        for _ <- 1..4, do: assert_receive(:started, 2_000)
        assert wait_until(fn -> OmnigateControl.Guard.supervisor(guard) != first end)
        # ...and the guard, still the same process, starts the group again after a pause.
        assert Process.alive?(guard)
        for _ <- 1..3, do: assert_receive(:started, 5_000)
        assert wait_until(fn -> is_pid(OmnigateControl.Guard.supervisor(guard)) end, 1_000)
        assert Process.alive?(OmnigateControl.Guard.supervisor(guard))
        GenServer.stop(guard)
      end)
    end

    test "four crashes of a store in a row do not take the listener down (the review's outage)" do
      listener = Enum.find_value(Supervisor.which_children(OmnigateControl.Root), fn {id, pid, _, _} -> if match?({Bandit, _}, id) or id == Bandit, do: pid end)
      assert is_pid(listener)
      group = Process.whereis(OmnigateControl.Supervisor)
      ref = Process.monitor(group)
      port = Application.fetch_env!(:omnigate_control, :port)

      capture_log(fn ->
        # Kill it until its supervisor gives up (the fourth crash inside five seconds).
        Enum.each(1..6, fn _ ->
          if Process.alive?(group) do
            pid = Process.whereis(Audit)
            if pid, do: Process.exit(pid, :kill)
            assert wait_until(fn -> not Process.alive?(group) or Process.whereis(Audit) not in [nil, pid] end)
          end
        end)

        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
        # ...and the listener answers: alive, and honest about not being ready.
        assert Process.alive?(listener)
        assert {:ok, %{status: 200}} = Http.request(:get, "http://127.0.0.1:#{port}/healthz", [])
        assert {:ok, %{status: 503, body: body}} = Http.request(:get, "http://127.0.0.1:#{port}/readyz", [])
        assert body =~ "not_ready"

        # Then everything comes back by itself.
        assert wait_until(fn -> Router.readiness() == :ok and is_pid(Process.whereis(Audit)) and is_pid(Process.whereis(Webhooks)) end, 1_000)
      end)

      assert Process.alive?(listener)
      assert Process.whereis(OmnigateControl.Supervisor) != group
      assert {:ok, %{status: 200}} = Http.request(:get, "http://127.0.0.1:#{port}/readyz", [])
    end
  end

  defp metrics do
    conn = conn(:get, "/metrics") |> bearer() |> call()
    {conn.status, conn.resp_body}
  end

  # ============================================================= M4: whose bodies are parsed

  describe "M4: request bodies are read only for callers who have authenticated" do
    test "anonymous bodies are neither read nor parsed, on any path or method" do
      bad_json = "{\"a\":"

      for {method, path, expected} <- [
            {:post, "/healthz", 404},
            {:post, "/readyz", 404},
            {:post, "/login/x", 404},
            {:delete, "/login", 404},
            {:put, "/login", 404},
            {:patch, "/logout", 404},
            {:post, "/logout", 302},
            {:post, "/", 302},
            {:delete, "/", 302},
            {:post, "/nothing-here", 404},
            {:post, "/admin/keys", 401},
            {:delete, "/admin/keys/x", 401},
            {:post, "/internal/v1/jobs", 401},
            {:post, "/internal/usage/batch", 401}
          ] do
        conn = conn(method, path, bad_json) |> put_req_header("content-type", "application/json") |> put_req_header("content-length", "5") |> call()
        assert conn.status == expected, "#{method} #{path} gave #{conn.status}"
        # Still in the socket: nobody read it. And the connection is closed rather than drained.
        assert {:ok, ^bad_json, _} = read_body(conn)
        assert get_resp_header(conn, "connection") == ["close"]
      end

      # A request without a body keeps its connection.
      assert get_resp_header(conn(:get, "/healthz") |> call(), "connection") == []
    end

    test "authenticated callers and the login form are still parsed, with their own limits" do
      # The internal API: parsed, so bad JSON is reported as such, and a good body is consumed.
      conn = conn(:post, "/internal/usage/batch", "{\"a\":") |> put_req_header("content-type", "application/json") |> internal() |> call()
      assert conn.status == 400 and json(conn)["error"]["code"] == "invalid_json"

      conn =
        conn(:post, "/internal/counters", "{\"counters\":[]}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", "15")
        |> internal()
        |> call()

      assert conn.status == 200
      assert {:ok, "", _} = read_body(conn)
      assert get_resp_header(conn, "connection") == []

      conn = conn(:post, "/admin/keys", "{\"a\":") |> put_req_header("content-type", "application/json") |> bearer() |> call()
      assert conn.status == 400 and json(conn)["error"]["code"] == "invalid_json"

      # The login form: a few KiB at most, declared or not.
      form = fn body ->
        conn(:post, "/login", body) |> put_req_header("content-type", "application/x-www-form-urlencoded") |> Map.put(:remote_ip, {10, 67, 0, 1})
      end

      assert (form.("password=nope") |> call()).status == 401
      assert (form.("password=" <> String.duplicate("a", 10_000)) |> call()).status == 413
      assert (form.("password=x") |> put_req_header("transfer-encoding", "chunked") |> call()).status == 413

      # Logout reads its CSRF field only for a signed-in browser.
      session = AdminAuth.issue_session()
      csrf = AdminAuth.csrf_token(session)

      out =
        conn(:post, "/logout", "_csrf=" <> csrf)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("cookie", AdminAuth.cookie_name() <> "=" <> session)
        |> call()

      assert out.status == 302

      denied =
        conn(:post, "/logout", "_csrf=wrong")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("cookie", AdminAuth.cookie_name() <> "=" <> session)
        |> call()

      assert denied.status == 403
    end
  end

  # ============================================================= M5: event ids

  defp boot(path, opts \\ []) do
    n = unique()
    tables = {:"w6_totals_#{n}", :"w6_seen_#{n}"}
    defaults = [path: path, name: nil, tables: tables, snapshot_every: 1_000_000, segment_bytes: 1_000_000_000, tick_ms: 3_600_000]
    {:ok, pid} = GenServer.start(Ledger, Keyword.merge(defaults, opts))
    pid
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    :ok
  end

  defp event(i, key \\ "k1"), do: %{"id" => Base.encode16(<<i::128>>, case: :lower), "key_sha256" => key, "status" => 200, "cost_usd" => 1.0}
  defp record(pid, range), do: GenServer.call(pid, {:record_batch, Enum.map(range, &event/1), :media})
  defp total(pid, key \\ "k1"), do: Enum.find_value(Ledger.dump(pid).totals, 0, fn {row, totals} -> if row == key, do: totals.requests end)

  describe "M5: event ids are small, on their own, and go a day at a time" do
    test "an id is two small integers, and ids that differ anywhere stay different" do
      assert {a, b} = Ids.key("000102030405060708090a0b0c0d0e0f")
      assert a in 0..(2 ** 59 - 1) and b in 0..(2 ** 59 - 1)
      assert Ids.key("job_abc") == Ids.key("job_abc")
      assert Ids.key("job_abc") != Ids.key("job_abd")
      # Ids that differ only in their last bits, as a counter's would.
      keys = for i <- 1..5_000, do: Ids.key(Base.encode16(<<i::128>>, case: :lower))
      assert length(Enum.uniq(keys)) == 5_000
    end

    test "ids live in per-day files next to the ledger; the snapshot only knows their lengths", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      {:ok, clock} = Agent.start_link(fn -> 1_794_300_000_000 end)
      pid = boot(path, clock: fn -> Agent.get(clock, & &1) end)

      assert {:ok, %{accepted: 100}} = record(pid, 1..100)
      Agent.update(clock, &(&1 + @day_ms))
      assert {:ok, %{accepted: 50}} = record(pid, 101..150)
      :ok = Ledger.snapshot(pid)

      assert [{"2026-11-10", day1}, {"2026-11-11", day2}] = Ids.files(path)
      assert File.stat!(day1).size == 100 * 16
      assert File.stat!(day2).size == 50 * 16

      assert {:ok, snapshot, :current} = Files.load_snapshot(path)
      assert snapshot.version == 2
      assert snapshot.ids == %{"2026-11-10" => 1600, "2026-11-11" => 800}
      refute Map.has_key?(snapshot, :seen)

      # Two thousand more ids do not make the snapshot any larger.
      size = File.stat!(Files.snapshot_path(path)).size
      assert {:ok, %{accepted: 2000}} = record(pid, 151..2150)
      :ok = Ledger.snapshot(pid)
      assert abs(File.stat!(Files.snapshot_path(path)).size - size) < 1_000

      # Both days are known after a crash, from the files and the replay.
      assert {:ok, %{accepted: 20}} = record(pid, 2151..2170)
      kill(pid)
      pid = boot(path, clock: fn -> Agent.get(clock, & &1) end)
      assert {:ok, %{accepted: 0, duplicates: 2170}} = record(pid, 1..2170)
      assert total(pid) == 2170
      assert File.stat!(day2).size == 2070 * 16
      GenServer.stop(pid)
    end

    test "old ids go a whole day at a time, never earlier than the window", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      start = 1_794_300_000_000
      {:ok, clock} = Agent.start_link(fn -> start end)
      pid = boot(path, clock: fn -> Agent.get(clock, & &1) end)

      {:ok, %{accepted: 10}} = record(pid, 1..10)
      Agent.update(clock, &(&1 + @day_ms))
      {:ok, %{accepted: 5}} = record(pid, 11..15)

      # A cutoff inside the first day: that day is not over, nothing goes.
      assert Ledger.prune_ids(start + 1_000, pid) == 0
      assert {:ok, %{duplicates: 10}} = record(pid, 1..10)

      # A cutoff inside the second day: the first day is over, and goes whole.
      assert Ledger.prune_ids(start + @day_ms + 1_000, pid) == 10
      refute File.exists?(Ids.file(path, "2026-11-10"))
      assert {:ok, %{accepted: 0, duplicates: 5}} = record(pid, 11..15)
      # The documented cost: an event resent after its id is gone counts again.
      assert {:ok, %{accepted: 10}} = record(pid, 1..10)
      assert total(pid) == 25

      # A restart does not bring forgotten ids back.
      kill(pid)
      pid = boot(path, clock: fn -> Agent.get(clock, & &1) end)
      assert length(Ledger.dump(pid).ids) == 15
      GenServer.stop(pid)
    end

    test "a snapshot from before this layout (ids inside it) is read once and replaced", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      pid = boot(path)
      {:ok, _} = record(pid, 1..20)
      expected = Ledger.dump(pid)
      GenServer.stop(pid)

      # Put back what the previous version would have left: a version 1
      # snapshot holding the ids themselves, and no id files.
      {:ok, v2, :current} = Files.load_snapshot(path)
      seen = for i <- 1..20, do: {Base.encode16(<<i::128>>, case: :lower), System.os_time(:millisecond)}
      Files.write_snapshot(path, %{version: 1, covered: v2.covered, totals: v2.totals, seen: seen, recent: [], taken_ms: 0})
      File.rm(Files.prev_path(path))
      for {_day, file} <- Ids.files(path), do: File.rm!(file)

      pid = boot(path)
      assert Ledger.dump(pid) == expected
      assert {:ok, %{accepted: 0, duplicates: 20}} = record(pid, 1..20)
      assert [{_today, file}] = Ids.files(path)
      assert File.stat!(file).size == 20 * 16
      assert {:ok, %{version: 2}, :current} = Files.load_snapshot(path)
      GenServer.stop(pid)
    end

    test "retention keeps ids for three days unless told otherwise, and says why" do
      assert ConfigStore.normalize(%{}).retention.ledger_ids_days == 3
      assert ConfigStore.normalize(%{"retention" => %{"ledger_ids_days" => 0.5}}).retention.ledger_ids_days == 0.5
    end
  end

  # ============================================================= L5 and L6: the ledger around a restart

  describe "L5: nobody reads a ledger that is still loading" do
    test "the tables get their names only after the snapshot and the replay", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      pid = boot(path)
      {:ok, _} = record(pid, 1..50)
      kill(pid)

      n = unique()
      tables = {:"w6_l5_totals_#{n}", :"w6_l5_seen_#{n}"}
      test = self()

      # Called from inside init, between loading the snapshot and replaying.
      clock = fn ->
        send(test, {:during_init, :ets.whereis(elem(tables, 0)), :ets.whereis(:"#{elem(tables, 0)}_loading") != :undefined})
        System.os_time(:millisecond)
      end

      {:ok, pid} = GenServer.start(Ledger, path: path, name: nil, tables: tables, clock: clock, snapshot_every: 1_000_000, tick_ms: 3_600_000)
      assert_receive {:during_init, :undefined, true}
      assert :ets.whereis(elem(tables, 0)) != :undefined
      assert [{"k1", %{requests: 50}}] = :ets.lookup(elem(tables, 0), "k1")
      GenServer.stop(pid)
    end

    test "while the ledger is down the config snapshot is refused, and budgets fail closed" do
      key = managed_key(%{"budget_usd" => 5})
      get_config = fn -> conn(:get, "/internal/config") |> internal() |> call() end
      assert get_config.().status == 200
      assert Ledger.ready?()

      capture_log(fn ->
        :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Ledger)

        try do
          refute Ledger.ready?()
          refused = get_config.()
          assert refused.status == 503
          assert %{"error" => %{"code" => "not_ready"}} = json(refused)
          # A key with a budget cannot start paid work on a guess of "nothing spent".
          assert post_job(key.key_sha256, %{"model" => "w6", "input" => %{"prompt" => "x"}}).status >= 500
          assert conn(:get, "/readyz") |> call() |> Map.get(:status) == 503
        after
          {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Ledger)
        end
      end)

      assert get_config.().status == 200
    end
  end

  describe "L6: a batch is counted once, whatever fails after it was written" do
    # The review's case: a batch is on disk and in the totals, then sealing
    # the segment fails (a full disk). `:before_rename` fails before anything
    # moved; `:after_rename` after the old file got its number but before the
    # new one exists, which is where the review made it fail.
    for step <- [:before_rename, :after_rename] do
      test "a seal that fails #{step} does not undo the batch, stop the ledger or double anything", %{dir: dir} do
        path = Path.join(dir, "ledger.jsonl")
        {:ok, failing} = Agent.start_link(fn -> true end)

        seal = fn path ->
          if Agent.get(failing, & &1) do
            if unquote(step) == :after_rename, do: Files.seal_rename(path, Files.active_seq(path))
            raise File.Error, reason: :enospc, action: "write to file", path: path
          else
            Files.seal(path)
          end
        end

        pid = boot(path, segment_bytes: 2_000, seal: seal)
        {:ok, %{accepted: 3}} = record(pid, 1..3)

        log = capture_log(fn -> assert {:ok, %{accepted: 37}} = record(pid, 4..40) end)
        assert log =~ "sealing segment 1 failed"
        assert Process.alive?(pid)
        assert total(pid) == 40
        # The data plane got its acknowledgement; if it resends anyway, nothing is counted twice.
        capture_log(fn -> assert {:ok, %{accepted: 0, duplicates: 37}} = record(pid, 4..40) end)

        # Once the disk is fine again the next batch seals as usual.
        Agent.update(failing, fn _ -> false end)
        {:ok, %{accepted: 30}} = record(pid, 41..70)
        assert Ledger.status(pid).segment >= 2
        assert total(pid) == 70

        # And a crash right now loses and doubles nothing.
        kill(pid)
        pid = boot(path, segment_bytes: 2_000)
        assert total(pid) == 70
        assert {:ok, %{accepted: 0, duplicates: 70}} = record(pid, 1..70)
        GenServer.stop(pid)
      end
    end

    test "a crashing ledger leaves no snapshot of state it did not finish; a clean stop does", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      pid = boot(path)
      {:ok, _} = record(pid, 1..10)
      :ok = Ledger.snapshot(pid)
      {:ok, _} = record(pid, 11..20)
      snapshot_before = File.read!(Files.snapshot_path(path))

      # Not a kill: the process runs terminate/2, with a reason that is not a shutdown.
      ref = Process.monitor(pid)
      capture_log(fn -> catch_exit(GenServer.call(pid, :no_such_call)) end)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert File.read!(Files.snapshot_path(path)) == snapshot_before

      pid = boot(path)
      assert total(pid) == 20
      {:ok, _} = record(pid, 21..25)
      GenServer.stop(pid)
      assert {:ok, %{covered: {1, offset}}, :current} = Files.load_snapshot(path)
      assert offset == File.stat!(path).size
    end

    test "events after the snapshot that the snapshot already counted are skipped on replay", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      pid = boot(path)
      {:ok, _} = record(pid, 1..3)
      before = :sys.get_state(pid)
      {:ok, _} = record(pid, 4..40)
      state = :sys.get_state(pid)
      dump = Ledger.dump(pid)
      kill(pid)

      # The inconsistent snapshot the review produced: totals and ids that
      # include the second batch, an offset from before it.
      Files.write_snapshot(path, %{
        version: 2,
        covered: {before.segment, before.offset},
        totals: dump.totals,
        ids: Ids.sizes(state.ids),
        recent: [],
        taken_ms: 0
      })

      File.rm(Files.prev_path(path))

      log = capture_log(fn -> send(self(), {:pid, boot(path)}) end)
      assert_receive {:pid, pid}
      assert log =~ "skipped 37 events"
      assert total(pid) == 40
      # The data plane's resend of that batch is recognised too.
      assert {:ok, %{accepted: 0, duplicates: 37}} = record(pid, 4..40)
      GenServer.stop(pid)
    end
  end

  # ============================================================= L8: numbers the data plane parses

  describe "L8: nothing in the config snapshot can overflow the data plane's fields" do
    test "the admin API refuses an rpm the data plane could not hold" do
      name = "w6-rpm-#{unique()}"

      create = fn rpm ->
        conn(:post, "/admin/keys", JSON.encode!(%{"name" => name, "rpm" => rpm})) |> put_req_header("content-type", "application/json") |> bearer() |> call()
      end

      for rpm <- [4_294_967_296, 10 ** 30, 1_000_001, -1, 1.5, "60"] do
        refused = create.(rpm)
        assert refused.status == 400, "rpm #{inspect(rpm)} gave #{refused.status}"
        assert json(refused)["error"]["message"] =~ "rpm"
      end

      assert create.(1_000_000).status == 201
      on_exit(fn -> Keys.delete(name) end)
      assert {:error, 400, _, _} = Keys.update(name, %{"max_open_jobs" => 10 ** 20})
      assert {:error, 400, _, _} = Keys.update(name, %{"budget_usd" => 1.0e300})
    end

    test "the config file is held to the same limits" do
      limits = ConfigStore.limits()
      key = fn rpm -> %{"keys" => [%{"name" => "k", "key" => "x", "rpm" => rpm}]} end

      route = fn route, target ->
        %{"routes" => [Map.merge(%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "t"}, target)]}, route)]}
      end

      upstream = fn ms -> %{"upstreams" => [%{"name" => "u", "kind" => "openai", "base_url" => "http://x", "api_key_env" => "K", "timeout_ms" => ms}]} end

      for bad <- [limits.rpm + 1, 2 ** 32, -1, 2.5],
          do: assert_raise(ArgumentError, ~r/"rpm" must be a whole number/, fn -> ConfigStore.normalize(key.(bad)) end)

      for bad <- [limits.weight + 1, 2 ** 32], do: assert_raise(ArgumentError, ~r/"weight"/, fn -> ConfigStore.normalize(route.(%{}, %{"weight" => bad})) end)

      for bad <- [limits.cache_ttl_s + 1, 2 ** 32],
          do: assert_raise(ArgumentError, ~r/"cache_ttl_s"/, fn -> ConfigStore.normalize(route.(%{"cache_ttl_s" => bad}, %{})) end)

      for bad <- [limits.timeout_ms + 1, 2 ** 32, -1, 0.5], do: assert_raise(ArgumentError, ~r/"timeout_ms"/, fn -> ConfigStore.normalize(upstream.(bad)) end)

      ok =
        ConfigStore.normalize(
          Map.merge(Map.merge(key.(limits.rpm), route.(%{"cache_ttl_s" => limits.cache_ttl_s}, %{"weight" => limits.weight})), upstream.(limits.timeout_ms))
        )

      assert hd(ok.keys).rpm == limits.rpm
    end

    test "every number in the snapshot fits the 32-bit fields of dataplane/src/config.zig" do
      limits = ConfigStore.limits()
      for {_name, limit} <- limits, do: assert(limit < 2 ** 32)

      name = "w6-snap-#{unique()}"
      {:ok, _key, _raw} = Keys.create(%{"name" => name, "rpm" => limits.rpm, "max_open_jobs" => 1_000_000_000, "budget_usd" => 1.0e12})
      on_exit(fn -> Keys.delete(name) end)

      snapshot = Router.snapshot() |> JSON.encode!() |> JSON.decode!()
      assert Enum.any?(snapshot["keys"], &(&1["name"] == name and &1["rpm"] == limits.rpm))

      numbers = fn numbers, term ->
        case term do
          n when is_number(n) -> [n]
          list when is_list(list) -> Enum.flat_map(list, &numbers.(numbers, &1))
          map when is_map(map) -> map |> Map.values() |> Enum.flat_map(&numbers.(numbers, &1))
          _ -> []
        end
      end

      for n <- numbers.(numbers, snapshot), do: assert(is_integer(n) and n >= 0 and n < 2 ** 32, "#{inspect(n)} is in the snapshot")

      # The fields these limits protect are still 32 bits wide in the data plane's source.
      source = Path.expand("../../dataplane/src/config.zig", __DIR__)

      if File.exists?(source) do
        zig = File.read!(source)
        for field <- ~w(rpm weight cache_ttl_s timeout_ms), do: assert(zig =~ ~r/\b#{field}: u32\b/, "#{field} is no longer a u32 in config.zig")
      end
    end
  end

  # ============================================================= L10 and the rest of the ledger

  describe "L10: small things that failed late or silently" do
    test "a ledger path without an extension seals and restarts like any other", %{dir: dir} do
      path = Path.join(dir, "ledger")
      pid = boot(path)
      {:ok, _} = record(pid, 1..5)
      assert {:ok, 2} = Ledger.rotate(pid)
      {:ok, _} = record(pid, 6..8)
      assert [{1, sealed}] = Files.sealed(path)
      assert Path.basename(sealed) == "ledger.000001"
      assert Path.basename(Files.snapshot_path(path)) == "ledger.snapshot"
      kill(pid)

      pid = boot(path)
      assert total(pid) == 8
      assert Ledger.status(pid).segment == 2
      GenServer.stop(pid)
    end

    test "a negative or non-numeric token price is refused when the config is loaded" do
      route = fn target -> %{"routes" => [%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "t"}, target)]}]} end

      for bad <- [%{"price_in_per_mtok" => -1}, %{"price_out_per_mtok" => -0.01}, %{"price_in_per_mtok" => "3"}, %{"price_out_per_mtok" => 1.0e300}] do
        assert_raise ArgumentError, ~r/a price must be a number of dollars per 1M tokens, 0 or more/, fn -> ConfigStore.normalize(route.(bad)) end
      end

      assert_raise ArgumentError, ~r/"budget_usd" must be a number of dollars/, fn ->
        ConfigStore.normalize(%{"keys" => [%{"name" => "k", "key" => "x", "budget_usd" => -5}]})
      end

      assert [%{price_in_per_mtok: 3.0, price_out_per_mtok: out}] = hd(ConfigStore.normalize(route.(%{"price_in_per_mtok" => 3})).routes).targets
      assert out == 0.0
    end

    test "usage for a route the config does not have is counted and logged once, not silently free" do
      key = hash()
      route = "w6-unknown-#{unique()}"
      before = Counters.get(:ledger_unpriced_events)

      event = fn ->
        %{
          "id" => "w6-#{unique()}",
          "key_sha256" => key,
          "status" => 200,
          "route_model" => route,
          "upstream" => "u",
          "target_model" => "t",
          "input_tokens" => 1000
        }
      end

      log =
        capture_log(fn ->
          assert {:ok, %{accepted: 2}} = Ledger.record_batch([event.(), event.()])
          assert {:ok, %{accepted: 1}} = Ledger.record_batch([event.()])
        end)

      assert Counters.get(:ledger_unpriced_events) == before + 3
      assert length(String.split(log, "usage for route #{route}")) == 2
      assert Ledger.spend(key) == 0.0
      assert {200, body} = metrics()
      assert body =~ ~r/^omnigate_ledger_unpriced_events_total \d+$/m

      # A request answered from the response cache, or one that never reached a provider, is not "unpriced".
      {:ok, _} =
        Ledger.record_batch([
          %{"key_sha256" => key, "status" => 200, "route_model" => route, "upstream" => "u", "cached" => true},
          %{"key_sha256" => key, "status" => 502}
        ])

      assert Counters.get(:ledger_unpriced_events) == before + 3
    end
  end

  # ============================================================= L1: the admin token

  describe "L1: the admin token is compared in one place, behind the throttle" do
    setup do
      Application.put_env(:omnigate_control, :bearer_max_failures, 3)
      on_exit(fn -> Application.put_env(:omnigate_control, :bearer_max_failures, 1_000_000) end)
      :ok
    end

    defp from(path, ip, token), do: conn(:get, path) |> bearer(token) |> Map.put(:remote_ip, ip) |> call()

    test "wrong tokens on the dashboard and the login page count, and then even the right one is not compared" do
      ip = {10, 68, 1, unique() |> rem(250)}

      # Before: the right token is recognised on both pages.
      assert from("/", ip, @admin).status == 200
      assert from("/login", ip, @admin).status == 302

      # These two paths used to be free guesses.
      assert from("/", ip, "guess-1").status == 302
      assert from("/login", ip, "guess-2").status == 200
      assert from("/", ip, "guess-3").status == 302
      assert AdminAuth.bearer_throttled?(ip)

      # Locked out: the right token gets exactly what a wrong one gets.
      # The login page too: a bearer token there is throttled like anywhere else.
      login = from("/login", ip, @admin)
      assert login.status == 429 and get_resp_header(login, "retry-after") == ["60"]
      assert from("/login", ip, "guess-4").status == 429
      # Without a token it is still the page: a browser is not a guess.
      assert (conn(:get, "/login") |> Map.put(:remote_ip, ip) |> call()).status == 200
      locked = from("/", ip, @admin)
      assert locked.status == 429 and get_resp_header(locked, "retry-after") == ["60"]
      assert from("/", ip, "guess-5").status == 429
      assert from("/admin/keys", ip, @admin).status == 429
      assert from("/metrics", ip, @admin).status == 429

      # A browser session from the same address still works, and so does another address.
      session = AdminAuth.issue_session()
      assert (conn(:get, "/") |> put_req_header("cookie", AdminAuth.cookie_name() <> "=" <> session) |> Map.put(:remote_ip, ip) |> call()).status == 200
      assert from("/", {10, 68, 2, 1}, @admin).status == 200
    end

    test "authenticate/1 says who is asking without ever comparing a throttled token" do
      ip = {10, 68, 3, unique() |> rem(250)}
      ask = fn headers -> conn(:get, "/x") |> with_headers(headers) |> Map.put(:remote_ip, ip) |> AdminAuth.authenticate() end

      assert ask.([]) == :none
      assert ask.([{"authorization", "Bearer " <> @admin}]) == :token
      assert ask.([{"cookie", AdminAuth.cookie_name() <> "=" <> AdminAuth.issue_session()}]) == :session
      for _ <- 1..3, do: assert(ask.([{"authorization", "Bearer nope"}]) == :denied)
      assert ask.([{"authorization", "Bearer " <> @admin}]) == :throttled
      assert ask.([{"authorization", "Basic abc"}]) == :throttled
      # No header is never a guess, throttled or not.
      assert ask.([]) == :none
    end
  end

  # ============================================================= L2: the audit log and anonymous traffic

  describe "L2: failed logins cost two lines per address a minute" do
    test "repeats are counted and written as one summary line; an admin action never waits behind them" do
      # The counts below are per minute; do not start in the last seconds of one.
      if rem(System.os_time(:second), 60) >= 56, do: Process.sleep(5_000)
      path = Application.fetch_env!(:omnigate_control, :audit_path)
      peer = {10, 69, 0, unique() |> rem(250)}
      address = peer |> :inet.ntoa() |> to_string()
      lines = fn -> path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1) |> Enum.filter(&(&1["address"] == address)) end

      login = fn ->
        conn(:post, "/login", "password=nope") |> put_req_header("content-type", "application/x-www-form-urlencoded") |> Map.put(:remote_ip, peer) |> call()
      end

      statuses = for _ <- 1..40, do: login.().status
      # Five wrong passwords, then the login throttle answers.
      assert Enum.count(statuses, &(&1 == 401)) == 5
      assert Enum.count(statuses, &(&1 == 429)) == 35

      # An operator's own action is recorded at once, in order, synced.
      :ok = Audit.record(conn(:post, "/x") |> Map.put(:remote_ip, peer), "key.update", "w6-probe", "ok", auth: "token")

      assert [
               %{"action" => "login", "outcome" => "denied", "auth" => "password"},
               %{"action" => "login", "outcome" => "throttled"},
               %{"action" => "key.update", "target" => "w6-probe"}
             ] = lines.()

      # When the minute is over, one line per outcome says how many more there were.
      :ok = Audit.flush(System.os_time(:second) + 60)

      assert [_, _, _, %{"outcome" => "denied", "repeats" => 4}, %{"outcome" => "throttled", "repeats" => 34}] =
               Enum.sort_by(lines.(), &Map.get(&1, "repeats", 0))

      assert Enum.any?(Audit.recent(10), &(&1["address"] == address and &1["repeats"] == 34))
      # Nothing is written twice.
      :ok = Audit.flush(System.os_time(:second) + 120)
      assert length(lines.()) == 5
    end

    test "a single failed login is one line and no summary" do
      path = Application.fetch_env!(:omnigate_control, :audit_path)
      peer = {10, 69, 1, unique() |> rem(250)}
      address = peer |> :inet.ntoa() |> to_string()

      assert (conn(:post, "/login", "password=nope")
              |> put_req_header("content-type", "application/x-www-form-urlencoded")
              |> Map.put(:remote_ip, peer)
              |> call()).status == 401

      :ok = Audit.flush(System.os_time(:second) + 60)

      assert [%{"outcome" => "denied"} = entry] =
               path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1) |> Enum.filter(&(&1["address"] == address))

      refute Map.has_key?(entry, "repeats")
    end
  end

  # ============================================================= L4: many jobs, large inputs

  describe "L4: listing and holding jobs stays cheap" do
    test "a key's newest jobs are read from an index, in order, without the other keys' jobs" do
      {mine, other} = {hash(), hash()}
      base_ms = System.os_time(:millisecond) + 10_000_000
      ids = for i <- 1..6, do: {i, job_id()}

      for {i, id} <- ids,
          do:
            {:ok, _} =
              Store.create(%{
                "id" => id,
                "status" => "succeeded",
                "key_sha256" => if(i == 4, do: other, else: mine),
                "created_ms" => base_ms + i,
                "finished_ms" => 1,
                "ledgered" => true
              })

      id = fn i -> ids |> List.keyfind(i, 0) |> elem(1) end

      assert Enum.map(Store.list_for_key(mine, 3), & &1["id"]) == [id.(6), id.(5), id.(3)]
      assert Enum.map(Store.list_for_key(mine, 100), & &1["id"]) == Enum.map([6, 5, 3, 2, 1], id)
      assert Enum.map(Store.list_for_key(other, 100), & &1["id"]) == [id.(4)]
      assert Store.list_for_key("nobody", 5) == []
      assert Enum.map(Store.recent(2), & &1["id"]) == [id.(6), id.(5)]

      # A purged job leaves the index too.
      removed = Store.purge_finished_before(2)
      assert Enum.sort(Enum.map(removed, & &1["id"])) == Enum.sort(Enum.map(1..6, id))
      assert Store.list_for_key(mine, 100) == []
    end

    test "listing jobs has its own rate limit, apart from creating them" do
      key = managed_key(%{"rpm" => 2})
      RateLimit.reset(key.key_sha256)
      RateLimit.reset({:list, key.key_sha256})
      list = fn -> conn(:get, "/internal/v1/jobs?limit=5") |> internal(key.key_sha256) |> call() end

      assert list.().status == 200
      assert list.().status == 200
      refused = list.()
      assert refused.status == 429
      assert %{"error" => %{"code" => "rate_limit_exceeded"}} = json(refused)
      assert [retry] = get_resp_header(refused, "retry-after")
      assert String.to_integer(retry) in 1..60
      # Listing did not use up the allowance for creating.
      assert post_job(key.key_sha256, %{"model" => "w6", "input" => %{"prompt" => "x"}}).status == 202
    end

    test "a large input is kept in a file, used by the job, shown on request and left out of lists" do
      key = managed_key(%{})
      prompt = String.duplicate("word ", 5_000)
      created = post_job(key.key_sha256, %{"model" => "w6", "input" => %{"prompt" => prompt, "n" => 1}})
      assert created.status == 202
      id = json(created)["id"]
      assert json(created)["input"]["prompt"] == prompt

      # The record in memory does not carry it.
      stored = Store.get(id)
      assert stored["input"] == nil and stored["input_file"] == true
      assert byte_size(:erlang.term_to_binary(stored)) < 4_000
      assert File.exists?(Store.input_path(id))

      # The provider got the whole input, and the job is priced from it.
      done = await(id)
      assert done["status"] == "succeeded"
      assert Stub.val(:last_input)["prompt"] == prompt
      assert Jobs.input(done)["prompt"] == prompt

      await(id, &(&1["ledgered"] == true))
      one = conn(:get, "/internal/v1/jobs/#{id}") |> internal(key.key_sha256) |> call()
      assert json(one)["input"]["prompt"] == prompt
      refute Map.has_key?(json(one), "input_omitted")

      list = conn(:get, "/internal/v1/jobs") |> internal(key.key_sha256) |> call()
      assert [%{"id" => ^id, "input" => nil, "input_omitted" => true}] = json(list)["data"]

      # A small input stays where it was.
      small = json(post_job(key.key_sha256, %{"model" => "w6", "input" => %{"prompt" => "short"}}))
      assert Store.get(small["id"])["input"] == %{"prompt" => "short"}
      refute File.exists?(Store.input_path(small["id"]))
      await(small["id"], &(&1["ledgered"] == true))

      # Retention removes the file with the job.
      removed = Store.purge_finished_before(System.os_time(:millisecond) + 1_000)
      assert Enum.any?(removed, &(&1["id"] == id))
      refute File.exists?(Store.input_path(id))
    end

    test "a job that is refused leaves no input file behind" do
      key = managed_key(%{"max_jobs_per_day" => 1})
      body = %{"model" => "w6", "input" => %{"prompt" => String.duplicate("x", 20_000)}}
      first = json(post_job(key.key_sha256, body))
      assert post_job(key.key_sha256, body).status == 429
      assert File.exists?(Store.input_path(first["id"]))
      # Only jobs that exist have a file.
      for file <- File.ls!(Path.dirname(Store.input_path(first["id"]))), do: assert(Store.get(String.replace_suffix(file, ".json", "")) != nil)
      await(first["id"])
    end

    test "an Idempotency-Key has to be text" do
      key = managed_key(%{})
      refused = post_job(key.key_sha256, %{"model" => "w6", "input" => %{"prompt" => "x"}}, [{"idempotency-key", <<"abc", 0xFF>>}])
      assert refused.status == 400
      assert json(refused)["error"]["message"] =~ "Idempotency-Key"
    end
  end

  # ============================================================= the rate limiter

  describe "the control plane's rate limit is the data plane's token bucket" do
    # The numbers of the tests in dataplane/src/ratelimit.zig.
    test "burst, then deny with a retry hint, then refill" do
      id = "w6-rl-#{unique()}"
      for _ <- 1..5, do: assert(:ok = RateLimit.check(id, 5, 1000))
      assert {:error, 12} = RateLimit.check(id, 5, 1000)

      # One request refills every 12 s.
      assert {:error, _} = RateLimit.check(id, 5, 1000 + 11_000)
      assert :ok = RateLimit.check(id, 5, 1000 + 12_000)
      assert {:error, _} = RateLimit.check(id, 5, 1000 + 12_001)

      # A long idle period refills to capacity, not beyond.
      for _ <- 1..5, do: assert(:ok = RateLimit.check(id, 5, 10_000_000))
      assert {:error, _} = RateLimit.check(id, 5, 10_000_000)
    end

    test "keys are independent and a changed limit starts with a full bucket" do
      {a, b} = {"w6-rl-a-#{unique()}", "w6-rl-b-#{unique()}"}
      assert :ok = RateLimit.check(a, 1, 0)
      assert {:error, 60} = RateLimit.check(a, 1, 0)
      assert :ok = RateLimit.check(b, 1, 0)
      assert :ok = RateLimit.check(a, 2, 0)
      for _ <- 1..100, do: assert(:ok = RateLimit.check(a, 0, 0))
    end

    test "requests arriving together never get more than the bucket holds" do
      id = "w6-rl-race-#{unique()}"
      results = 1..200 |> Task.async_stream(fn _ -> RateLimit.check(id, 50, 5_000) end, max_concurrency: 50) |> Enum.map(&elem(&1, 1))
      assert Enum.count(results, &(&1 == :ok)) == 50
    end

    test "it is counted per key, not per name, and a replayed Idempotency-Key is not counted" do
      key = managed_key(%{"rpm" => 1})
      other = managed_key(%{"rpm" => 1})
      for k <- [key, other], do: RateLimit.reset(k.key_sha256)
      body = %{"model" => "w6", "input" => %{"prompt" => "x"}}
      idem = [{"idempotency-key", "w6-idem-#{unique()}"}]

      first = post_job(key.key_sha256, body, idem)
      assert first.status == 202
      # The same request again creates nothing, so it is not refused and takes nothing.
      for _ <- 1..5 do
        again = post_job(key.key_sha256, body, idem)
        assert again.status == 200 and json(again)["id"] == json(first)["id"]
      end

      # A new request is over the limit, with the data plane's retry hint.
      refused = post_job(key.key_sha256, body)
      assert refused.status == 429
      assert get_resp_header(refused, "retry-after") == ["60"]
      # Another key has its own bucket.
      assert post_job(other.key_sha256, body).status == 202
    end
  end

  # ============================================================= M2: what a job is billed for

  describe "M2: a media job's price does not follow what the client declares" do
    @per_second %{per_job_usd: 0.0, per_output_usd: 0.0, per_input_char_usd: 0.0, per_second_usd: 1.0}

    defp run_job(input) do
      case Jobs.create(hash(), %{"model" => "w6", "input" => input}) do
        {:ok, job} -> await(job["id"])
        other -> other
      end
    end

    test "per-second prices use the target's default and minimum, and refuse what is above its maximum", %{base: base} do
      ConfigStore.put_media(media(base, price: @per_second, target: %{default_seconds: 5, min_seconds: 2, max_seconds: 10}))

      # No duration in the request: the default, not zero.
      assert %{"status" => "succeeded", "cost_usd" => 5.0} = run_job(%{"prompt" => "x"})
      # A tiny declared duration is billed at the minimum; zero is "none given".
      assert %{"cost_usd" => 2.0} = run_job(%{"prompt" => "x", "duration" => 0.01})
      assert %{"cost_usd" => 5.0} = run_job(%{"prompt" => "x", "duration" => 0})
      # In between: what was asked for, as a number or the ways providers spell it.
      assert %{"cost_usd" => 7.0} = run_job(%{"prompt" => "x", "duration" => 7})
      assert %{"cost_usd" => 4.0} = run_job(%{"prompt" => "x", "duration" => "4s"})
      assert %{"cost_usd" => 2.5} = run_job(%{"prompt" => "x", "seconds" => "2.5"})

      assert {:error, 400, "invalid_request", message} = run_job(%{"prompt" => "x", "duration" => 11})
      assert message =~ "at most 10 seconds"
      assert {:error, 400, "invalid_request", _} = run_job(%{"prompt" => "x", "duration" => "11s"})

      for bad <- ["soon", "5 minutes", -1, "-3s", [5], %{"s" => 5}],
          do: assert({:error, 400, "invalid_request", _} = run_job(%{"prompt" => "x", "duration" => bad}))
    end

    test "a per-second price with nothing to multiply is refused, saying what to send", %{base: base} do
      ConfigStore.put_media(media(base, price: @per_second))
      assert {:error, 400, "invalid_request", message} = run_job(%{"prompt" => "x"})
      assert message =~ "priced per second" and message =~ "input.duration"
      assert {:error, 400, "invalid_request", _} = run_job(%{"prompt" => "x", "duration" => 0})
      assert %{"cost_usd" => 3.0} = run_job(%{"prompt" => "x", "duration" => 3})

      # Without a per-second price a duration is optional, but still has to be one.
      ConfigStore.put_media(media(base))
      assert %{"status" => "succeeded", "cost_usd" => 0.25} = run_job(%{"prompt" => "x"})
      assert %{"status" => "succeeded"} = run_job(%{"prompt" => "x", "duration" => "5s"})
      assert {:error, 400, "invalid_request", _} = run_job(%{"prompt" => "x", "duration" => "soon"})
    end

    test "a route can list the input fields it accepts", %{base: base} do
      ConfigStore.put_media(media(base, route: %{allowed_input: ["prompt", "size"]}))
      assert %{"status" => "succeeded"} = run_job(%{"prompt" => "x", "size" => "1024x1024"})
      assert {:error, 400, "invalid_request", message} = run_job(%{"prompt" => "x", "quality" => "high", "n" => 10})
      assert message =~ "n, quality" and message =~ "allowed: prompt, size"
    end

    test "a route can price input options, and then only listed values are accepted", %{base: base} do
      multipliers = %{
        "quality" => %{"low" => 1.0, "high" => 4.0, "default" => 2.0},
        "size" => %{"1024x1024" => 1.0, "1536x1024" => 1.5},
        "n" => %{"1" => 1.0, "2" => 2.0}
      }

      ConfigStore.put_media(media(base, route: %{price_multipliers: multipliers}))

      assert %{"cost_usd" => 0.5} = run_job(%{"prompt" => "x"})
      assert %{"cost_usd" => 0.25} = run_job(%{"prompt" => "x", "quality" => "low"})
      assert %{"cost_usd" => 1.0} = run_job(%{"prompt" => "x", "quality" => "high"})
      assert %{"cost_usd" => 1.5} = run_job(%{"prompt" => "x", "quality" => "high", "size" => "1536x1024"})
      assert %{"cost_usd" => 3.0} = run_job(%{"prompt" => "x", "quality" => "high", "size" => "1536x1024", "n" => 2})

      assert {:error, 400, "invalid_request", message} = run_job(%{"prompt" => "x", "quality" => "ultra"})
      assert message =~ "\"input.quality\" must be one of: high, low"
      assert {:error, 400, "invalid_request", _} = run_job(%{"prompt" => "x", "size" => ["1536x1024"]})

      # If the config changes under a running job, an unlisted value costs the highest factor of its field.
      assert Jobs.multiplier(%{price_multipliers: multipliers}, %{"quality" => "ultra"}) == 4.0
      assert Jobs.multiplier(%{}, %{"quality" => "ultra"}) == 1.0
    end

    test "the new settings are validated when the config is loaded" do
      config = fn route, target ->
        %{
          "media" => %{
            "routes" => [
              Map.merge(%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "t", "price" => %{"per_second_usd" => 0.1}}, target)]}, route)
            ]
          }
        }
      end

      [route] =
        ConfigStore.normalize(
          config.(%{"allowed_input" => ["prompt", "prompt", "size"], "price_multipliers" => %{"quality" => %{"high" => 4, "low" => 1}}}, %{
            "default_seconds" => 5,
            "min_seconds" => 1,
            "max_seconds" => 10
          })
        ).media.routes

      assert route.allowed_input == ["prompt", "size"]
      assert route.price_multipliers == %{"quality" => %{"high" => 4.0, "low" => 1.0}}
      assert [%{default_seconds: 5, min_seconds: 1, max_seconds: 10}] = route.targets

      [plain] = ConfigStore.normalize(config.(%{}, %{})).media.routes
      assert plain.allowed_input == nil and plain.price_multipliers == %{}
      assert [%{default_seconds: nil, min_seconds: nil, max_seconds: nil}] = plain.targets

      for {route, target, message} <- [
            {%{}, %{"default_seconds" => -1}, ~r/"default_seconds" must be a number of seconds/},
            {%{}, %{"default_seconds" => 0}, ~r/"default_seconds" must be above 0/},
            {%{}, %{"min_seconds" => "2"}, ~r/"min_seconds" must be a number of seconds/},
            {%{}, %{"min_seconds" => 5, "max_seconds" => 2}, ~r/"min_seconds" must not be above "max_seconds"/},
            {%{}, %{"default_seconds" => 20, "max_seconds" => 10}, ~r/"default_seconds" must not be above "max_seconds"/},
            {%{"allowed_input" => "prompt"}, %{}, ~r/"allowed_input" must be a list/},
            {%{"allowed_input" => ["prompt", 5]}, %{}, ~r/"allowed_input" must be a list/},
            {%{"price_multipliers" => [1]}, %{}, ~r/"price_multipliers" must be an object/},
            {%{"price_multipliers" => %{"quality" => 4}}, %{}, ~r/must map each allowed value to a factor/},
            {%{"price_multipliers" => %{"quality" => %{"high" => -1}}}, %{}, ~r/must map each allowed value to a factor/},
            {%{"price_multipliers" => %{"quality" => %{}}}, %{}, ~r/must map each allowed value to a factor/},
            {%{"timeout_s" => 0}, %{}, ~r/"timeout_s" must be a whole number/}
          ] do
        assert_raise ArgumentError, message, fn -> ConfigStore.normalize(config.(route, target)) end
      end
    end

    test "durations are numbers, numeric strings, or a number followed by s" do
      for {value, seconds} <- [{5, 5}, {2.5, 2.5}, {"5", 5.0}, {" 7.5 ", 7.5}, {"5s", 5.0}, {"0", 0.0}],
          do: assert(Adapter.seconds_value(value) == {:ok, seconds})

      for bad <- [-1, "-1", "5m", "s", "", "5 s", nil, true, [5], 1.0e12, String.duplicate("9", 40)], do: assert(Adapter.seconds_value(bad) == :error)
      assert Adapter.seconds(%{"duration" => "5s", "seconds" => 3}, ~w(duration seconds)) == 5.0
      assert Jobs.billed_seconds(%{default_seconds: 5, min_seconds: 2}, 0) == 5
      assert Jobs.billed_seconds(%{default_seconds: 5, min_seconds: 2}, 1) == 2
      assert Jobs.billed_seconds(%{}, 3) == 3
    end
  end

  # ============================================================= one error table, two sources

  describe "errors.ex mirrors dataplane/src/errors.zig" do
    test "the reason-to-category table is the Zig one, row for row" do
      source = Path.expand("../../dataplane/src/errors.zig", __DIR__)

      if File.exists?(source) do
        zig = File.read!(source)
        [_, table] = Regex.run(~r/pub fn typesFor\(.*?const table = \[_\]struct \{[^}]*\}\{(.*?)\n    \};/s, zig)
        rows = Regex.scan(~r/\.\{ "([a-z_]+)", \.\{ \.openai = "([a-z_]+)"/, table) |> Map.new(fn [_, reason, openai] -> {reason, openai} end)

        assert map_size(rows) >= 10, "could not read the table out of errors.zig"
        assert rows == Errors.by_reason()

        # And the fallback by status, for a reason that is in neither table.
        [_, fallback] = Regex.run(~r/return switch \(status\) \{(.*?)\n    \};/s, zig)
        rows = Regex.scan(~r/^\s*([0-9., ]+|else) => \.\{ \.openai = "([a-z_]+)"/m, fallback)
        assert length(rows) >= 5, "could not read the status fallback out of errors.zig"

        listed =
          for [_, statuses, openai] <- rows, statuses != "else", part <- String.split(statuses, ","), into: %{} do
            [first | rest] = part |> String.trim() |> String.split("...")
            {String.to_integer(first)..String.to_integer(List.last([first | rest])), openai}
          end

        [[_, _, otherwise]] = Enum.filter(rows, fn [_, statuses, _] -> statuses == "else" end)

        for status <- 400..599 do
          expected = Enum.find_value(listed, otherwise, fn {range, openai} -> if status in range, do: openai end)
          assert Errors.category("some_unlisted_reason", status) == expected, "status #{status}"
        end
      end
    end
  end

  # ============================================================= close-out round

  describe "close-out: a key's max_concurrent" do
    test "the admin API takes it, bounds it and shows it, and the snapshot carries it to the data plane" do
      name = "co-conc-#{unique()}"

      send = fn method, path, body ->
        conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json") |> bearer() |> call()
      end

      for bad <- [-1, 1_000_001, 2 ** 32, 1.5, "4", true] do
        refused = send.(:post, "/admin/keys", %{"name" => name, "max_concurrent" => bad})
        assert refused.status == 400, "max_concurrent #{inspect(bad)} gave #{refused.status}"
        assert json(refused)["error"]["message"] =~ "max_concurrent"
      end

      created = send.(:post, "/admin/keys", %{"name" => name, "max_concurrent" => 4})
      on_exit(fn -> Keys.delete(name) end)
      assert created.status == 201 and json(created)["max_concurrent"] == 4
      in_snapshot = fn -> Router.snapshot() |> JSON.encode!() |> JSON.decode!() |> Map.fetch!("keys") |> Enum.find(&(&1["name"] == name)) end
      assert in_snapshot.()["max_concurrent"] == 4

      assert send.(:patch, "/admin/keys/#{name}", %{"max_concurrent" => 1_000_001}).status == 400
      assert json(send.(:patch, "/admin/keys/#{name}", %{"max_concurrent" => 1_000_000}))["max_concurrent"] == 1_000_000
      assert in_snapshot.()["max_concurrent"] == 1_000_000
      # null, like 0, is "the gateway's default".
      assert json(send.(:patch, "/admin/keys/#{name}", %{"max_concurrent" => nil}))["max_concurrent"] == 0
      assert in_snapshot.()["max_concurrent"] == 0
      # A key made without it has the default, and every key in the snapshot says so.
      assert Enum.all?(Router.snapshot().keys, &(is_integer(&1.max_concurrent) and &1.max_concurrent >= 0))
      assert Enum.any?(json(conn(:get, "/admin/keys") |> bearer() |> call())["keys"], &(&1["name"] == name and &1["max_concurrent"] == 0))
    end

    test "the config file is held to the same bounds, and the data plane's field is as wide" do
      limit = ConfigStore.limits().max_concurrent
      key = fn value -> %{"keys" => [%{"name" => "k", "key" => "x", "max_concurrent" => value}]} end

      for bad <- [limit + 1, 2 ** 32, -1, 2.5, "8"],
          do: assert_raise(ArgumentError, ~r/"max_concurrent"/, fn -> ConfigStore.normalize(key.(bad)) end)

      assert hd(ConfigStore.normalize(key.(limit)).keys).max_concurrent == limit
      assert hd(ConfigStore.normalize(key.(0)).keys).max_concurrent == 0
      assert hd(ConfigStore.normalize(%{"keys" => [%{"name" => "k", "key" => "x"}]}).keys).max_concurrent == 0

      source = Path.expand("../../dataplane/src/config.zig", __DIR__)
      if File.exists?(source), do: assert(File.read!(source) =~ ~r/\bmax_concurrent: u32\b/)
    end

    test "the dashboard shows a key's own cap" do
      name = "co-dash-#{unique()}"
      {:ok, _key, _raw} = Keys.create(%{"name" => name, "rpm" => 60, "max_concurrent" => 12})
      on_exit(fn -> Keys.delete(name) end)
      page = conn(:get, "/") |> bearer() |> call()
      assert page.status == 200 and page.resp_body =~ "12 at once"
    end
  end

  describe "close-out: per-second prices on providers that are never sent a duration" do
    test "the config is refused at load unless the target says how many seconds to bill" do
      config = fn kind, target ->
        %{
          "media" => %{
            "upstreams" => [%{"name" => "u", "kind" => kind, "base_url" => "http://x/", "api_key_env" => "K"}],
            "routes" => [%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "o/m", "price" => %{"per_second_usd" => 0.1}}, target)]}]
          }
        }
      end

      target = fn config -> config |> ConfigStore.normalize() |> then(&hd(hd(&1.media.routes).targets)) end

      for kind <- ~w(openai_images elevenlabs gemini gemini_interactions) do
        assert_raise ArgumentError, ~r/"per_second_usd", but a #{kind} provider is never sent a duration.*"default_seconds"/s, fn ->
          ConfigStore.normalize(config.(kind, %{}))
        end

        assert target.(config.(kind, %{"default_seconds" => 8})).default_seconds == 8
        # A price of zero per second is no per-second price.
        assert target.(config.(kind, %{"price" => %{"per_second_usd" => 0, "per_job_usd" => 1}})).price.per_job_usd == 1
      end

      # Providers that take the duration from the request need no default.
      for kind <- ~w(replicate fal xai_video), do: assert(target.(config.(kind, %{})).price.per_second_usd == 0.1)
    end

    test "such a job is billed the target's default, whatever duration the request names", %{base: base} do
      media = media(base, price: @per_second, target: %{default_seconds: 5, max_seconds: 10})
      ConfigStore.put_media(%{media | upstreams: [%{hd(media.upstreams) | kind: "openai_images"}]})

      assert %{"status" => "succeeded", "cost_usd" => 5.0} = run_job(%{"prompt" => "x"})
      # The provider is not sent a duration, so one in the request neither
      # changes the bill nor gets the request refused for being "too long".
      assert %{"status" => "succeeded", "cost_usd" => 5.0} = run_job(%{"prompt" => "x", "duration" => 7})
      assert %{"status" => "succeeded", "cost_usd" => 5.0} = run_job(%{"prompt" => "x", "duration" => 60})
      # It still has to be a duration.
      assert {:error, 400, "invalid_request", _} = run_job(%{"prompt" => "x", "duration" => "soon"})
    end
  end

  describe "close-out: the daily job limit" do
    test "says when to come back: at midnight UTC, and never more than an hour away" do
      key = managed_key(%{"max_jobs_per_day" => 1})
      body = %{"model" => "w6", "input" => %{"prompt" => "x"}}
      first = json(post_job(key.key_sha256, body))
      refused = post_job(key.key_sha256, body)
      assert refused.status == 429 and json(refused)["error"]["code"] == "too_many_jobs_today"
      assert [seconds] = get_resp_header(refused, "retry-after")
      now = DateTime.utc_now()
      to_midnight = 86_400 - (now.hour * 3_600 + now.minute * 60 + now.second)
      assert_in_delta String.to_integer(seconds), min(to_midnight, 3_600), 3
      assert String.to_integer(seconds) in 1..3_600
      await(first["id"])
    end
  end

  describe "close-out: the audit log" do
    defp wrong_password(peer, headers \\ []) do
      conn(:post, "/login", "password=nope")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> with_headers(headers)
      |> Map.put(:remote_ip, peer)
      |> call()
    end

    defp audit_lines(address) do
      Application.fetch_env!(:omnigate_control, :audit_path)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(&1["address"] == address))
    end

    test "a clean stop writes the counts that have no summary line yet, and the dashboard shows them" do
      # The counts are per minute; do not start in the last seconds of one.
      if rem(System.os_time(:second), 60) >= 56, do: Process.sleep(5_000)
      peer = {10, 71, 0, unique() |> rem(250)}
      address = peer |> :inet.ntoa() |> to_string()
      for _ <- 1..4, do: assert(wrong_password(peer).status == 401)

      capture_log(fn ->
        :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Audit)
        {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Audit)
      end)

      assert [first, %{"outcome" => "denied", "repeats" => 3, "auth" => "password"} = summary] = audit_lines(address)
      assert first["outcome"] == "denied" and not Map.has_key?(first, "repeats")
      # The minute was not over: the line is stamped when it was written, never in the future.
      {:ok, at, 0} = DateTime.from_iso8601(summary["ts"])
      assert DateTime.compare(at, DateTime.utc_now()) != :gt
      # Other tests' summary lines may be written in the same stop: look for ours.
      assert %{"address" => ^address, "repeats" => 3} = Enum.find(Audit.recent(50), &(&1["address"] == address and &1["repeats"]))

      page = conn(:get, "/") |> bearer() |> call()
      assert page.resp_body =~ ~s(<span class="muted sub">3 more</span>)
      overview = json(conn(:get, "/admin/overview") |> bearer() |> call())
      assert Enum.any?(overview["audit"], &(&1["address"] == address and &1["repeats"] == 3))

      # Nothing is written a second time when the minute is over.
      :ok = Audit.flush(System.os_time(:second) + 120)
      assert length(audit_lines(address)) == 2
    end

    test "the first line and the summary name the same address, also behind a trusted proxy" do
      if rem(System.os_time(:second), 60) >= 56, do: Process.sleep(5_000)
      System.put_env("OMNIGATE_TRUST_FORWARDED", "1")
      on_exit(fn -> System.delete_env("OMNIGATE_TRUST_FORWARDED") end)
      client = "203.0.113.#{unique() |> rem(250)}"
      peer = {10, 72, 0, 7}
      forwarded = [{"x-forwarded-for", client}]

      for _ <- 1..3, do: assert(wrong_password(peer, forwarded).status == 401)
      :ok = Audit.flush(System.os_time(:second) + 60)

      assert [first, summary] = audit_lines(client)
      assert %{"address" => ^client, "peer" => "10.72.0.7", "forwarded_for" => ^client, "outcome" => "denied"} = first
      assert %{"address" => ^client, "outcome" => "denied", "repeats" => 2} = summary
      refute Map.has_key?(summary, "peer")
      # Nothing was recorded under the proxy's address.
      assert Enum.filter(audit_lines("10.72.0.7"), &(&1["forwarded_for"] == client)) == []

      # An operator's action is recorded by the same rule ...
      action = fn ->
        conn(:post, "/x") |> with_headers(forwarded) |> Map.put(:remote_ip, peer) |> Audit.record("key.update", "co-probe", "ok", auth: "token")
      end

      :ok = action.()
      assert %{"target" => "co-probe", "address" => ^client, "peer" => "10.72.0.7", "forwarded_for" => ^client} = hd(Audit.recent(1))
      # ... and without the setting the address is the peer, with nothing to add to it.
      System.delete_env("OMNIGATE_TRUST_FORWARDED")
      :ok = action.()
      assert %{"target" => "co-probe", "address" => "10.72.0.7", "forwarded_for" => ^client} = entry = hd(Audit.recent(1))
      refute Map.has_key?(entry, "peer")
    end
  end

  describe "close-out: small things" do
    test "an id file the snapshot counted and that is gone is reported when the ledger is read", %{dir: dir} do
      path = Path.join(dir, "ledger.jsonl")
      File.write!(Ids.file(path, "2026-11-09"), :binary.copy(<<1>>, 32))
      registry = :ets.new(:co_ids_registry, [:set, :public])

      log =
        capture_log(fn ->
          ids = Ids.load(path, registry, %{"2026-11-09" => 32, "2026-11-08" => 160, "2026-11-07" => 0})
          assert Map.keys(ids.days) == ["2026-11-09"]
        end)

      assert log =~ "2026-11-08" and log =~ "is missing" and log =~ "10 ids" and log =~ "counted twice"
      refute log =~ "2026-11-09"
      refute log =~ "2026-11-07"
      # Nothing to say when every counted day is there.
      refute capture_log(fn -> Ids.load(path, registry, %{"2026-11-09" => 32}) end) =~ "is missing"
    end
  end
end
