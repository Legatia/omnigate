defmodule OmnigateControl.JobsTest.Stub do
  @moduledoc """
  In-test stand-in for a Replicate-style provider, an OpenAI-style image
  endpoint, a TTS endpoint and a webhook receiver, all on one port.

  Paths under `/bad` are a provider whose predictions fail.
  """
  use Plug.Router

  @table :omnigate_test_stub

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"], body_reader: {__MODULE__, :read_body, []}
  plug :dispatch

  # Keep the exact bytes: webhook signatures are over the raw body.
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
  end

  def setup do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    :ets.delete_all_objects(@table)
  end

  def count(name) do
    case :ets.lookup(@table, {:count, name}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  def hooks, do: :ets.lookup(@table, :hooks) |> Enum.flat_map(&elem(&1, 1)) |> Enum.reverse()
  def put(key, value), do: :ets.insert(@table, {key, value})

  defp bump(name), do: :ets.update_counter(@table, {:count, name}, 1, {{:count, name}, 0})

  defp val(key, default) do
    case :ets.lookup(@table, key) do
      [{_, v}] -> v
      [] -> default
    end
  end

  defp base(conn), do: "http://127.0.0.1:#{conn.port}"

  # Replicate-style create: prediction ids encode whether they should fail.
  post "/:flavor/v1/models/:owner/:name/predictions" do
    bump({flavor, :submit})
    id = "#{flavor}-#{System.unique_integer([:positive])}"
    send_json(conn, 201, %{id: id, status: "starting", output: nil, error: nil})
  end

  get "/:flavor/v1/predictions/:id" do
    polls = bump({:poll, id})

    body =
      cond do
        polls < val(:polls_needed, 2) -> %{id: id, status: "processing", output: nil}
        flavor == "bad" -> %{id: id, status: "failed", error: "boom", output: nil}
        true -> %{id: id, status: "succeeded", output: ["#{base(conn)}/files/#{id}.png"]}
      end

    send_json(conn, 200, body)
  end

  post "/:flavor/v1/predictions/:id/cancel" do
    bump({flavor, :cancel})
    send_json(conn, 200, %{id: id, status: "canceled"})
  end

  get "/files/:name" do
    bump(:download)
    conn |> put_resp_content_type("image/png") |> send_resp(200, "PNG-BYTES-" <> name)
  end

  post "/v1/images/generations" do
    bump(:image_call)
    send_json(conn, 200, %{created: 1, data: [%{b64_json: Base.encode64("inline-image")}]})
  end

  post "/v1/text-to-speech/:voice" do
    bump(:tts_call)
    conn |> put_resp_content_type("audio/mpeg") |> send_resp(200, "MP3:" <> voice <> ":" <> conn.body_params["text"])
  end

  # Webhook receiver: fails the first `:hook_failures` deliveries.
  post "/hook" do
    n = bump(:hook)
    body = conn.assigns.raw_body

    record = %{
      id: get_req_header(conn, "webhook-id") |> List.first(),
      timestamp: get_req_header(conn, "webhook-timestamp") |> List.first(),
      signature: get_req_header(conn, "webhook-signature") |> List.first(),
      body: body
    }

    :ets.insert(@table, {:hooks, [record | val(:hooks, [])]})
    if n <= val(:hook_failures, 0), do: send_resp(conn, 500, "no"), else: send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp send_json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end

defmodule OmnigateControl.JobsTest do
  # Not async: jobs, the ledger and the config are shared named processes.
  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{ConfigStore, Jobs, Ledger, Router, Webhooks}
  alias OmnigateControl.Jobs.{Runner, Store}
  alias OmnigateControl.JobsTest.Stub

  # Built here rather than written out: a literal `whsec_...` string trips
  # secret scanners (Stripe uses the same prefix). This one is a placeholder.
  @secret "whsec_" <> Base.encode64("test-webhook-secret")
  @token "test-internal-token"

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Stub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("OMNIGATE_TEST_PROVIDER_KEY", "provider-secret")
    System.put_env("OMNIGATE_INTERNAL_TOKEN", @token)
    original = ConfigStore.get().media
    base = "http://127.0.0.1:#{port}"

    on_exit(fn ->
      ConfigStore.put_media(original)
      System.delete_env("OMNIGATE_INTERNAL_TOKEN")
    end)

    {:ok, base: base}
  end

  setup %{base: base} do
    # Jobs a previous test left running would hit the stub's fresh counters.
    wait_idle()
    Stub.setup()

    price = %{per_job_usd: 0.0, per_output_usd: 0.25, per_input_char_usd: 0.0, per_second_usd: 0.0}
    upstream = fn name, kind, path -> %{name: name, kind: kind, base_url: base <> path, api_key_env: "OMNIGATE_TEST_PROVIDER_KEY"} end
    route = fn model, targets, cache -> %{model: model, cache_ttl_s: cache, timeout_s: 30, targets: targets} end
    target = fn up, p -> %{upstream: up, model: "owner/model", price: p} end

    ConfigStore.put_media(%{
      public_base_url: "http://gateway.test",
      poll_interval_ms: 10,
      max_output_bytes: 1_000_000,
      upstreams: [
        upstream.("bad", "replicate", "/bad"),
        upstream.("good", "replicate", "/good"),
        upstream.("images", "openai_images", ""),
        upstream.("tts", "elevenlabs", ""),
        %{name: "nokey", kind: "replicate", base_url: base <> "/good", api_key_env: "OMNIGATE_TEST_UNSET_ENV"}
      ],
      routes: [
        route.("img", [target.("bad", price), target.("good", price)], nil),
        route.("img-good", [target.("good", price)], nil),
        route.("img-bad", [target.("nokey", price), target.("bad", price)], nil),
        route.("img-sync", [target.("images", price)], nil),
        route.("tts", [target.("tts", %{price | per_output_usd: 0.0, per_input_char_usd: 0.01})], 3600)
      ],
      storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600},
      webhooks: %{retry_schedule_ms: [30, 30, 30], max_attempts: 4, timeout_ms: 2_000, allow_private: true, secret: @secret}
    })

    {:ok, key: "key-#{System.unique_integer([:positive])}"}
  end

  defp wait_idle(tries \\ 500) do
    busy = Enum.reject(Store.all(), &Jobs.terminal?/1)

    cond do
      busy == [] -> :ok
      tries == 0 -> Enum.each(busy, &Jobs.finish(&1["id"], "canceled", %{}))
      true -> Process.sleep(10) && wait_idle(tries - 1)
    end
  end

  defp await(id, pred \\ &Jobs.terminal?/1, tries \\ 300) do
    job = Store.get(id)

    cond do
      pred.(job) -> job
      tries == 0 -> flunk("timed out waiting for job #{id}: #{inspect(job)}")
      true -> Process.sleep(10) && await(id, pred, tries - 1)
    end
  end

  defp create!(key, params, idem \\ nil) do
    {:ok, job} = Jobs.create(key, params, idem)
    job
  end

  test "a job fails over, re-hosts its output, is billed once and reports by signed webhook", %{key: key, base: base} do
    Stub.put(:hook_failures, 2)

    job = create!(key, %{"model" => "img", "input" => %{"prompt" => "a cat"}, "webhook_url" => base <> "/hook", "metadata" => %{"order" => 7}})
    assert job["status"] == "queued"
    assert String.starts_with?(job["id"], "job_")

    job = await(job["id"])
    assert job["status"] == "succeeded"
    assert job["upstream"] == "good"
    assert [%{"upstream" => "bad", "outcome" => "provider_failed: boom"}, %{"upstream" => "good", "outcome" => "ok"}] = job["attempts"]
    assert Stub.count({"bad", :submit}) == 1 and Stub.count({"good", :submit}) == 1

    # Output was copied into our storage and hashed.
    [output] = job["outputs"]
    stored = Path.join([Application.fetch_env!(:omnigate_control, :media_dir), job["id"], output["name"]])
    content = File.read!(stored)
    assert String.starts_with?(content, "PNG-BYTES-good-")
    assert output["bytes"] == byte_size(content)
    assert output["sha256"] == OmnigateControl.sha256_hex(content)
    assert output["content_type"] == "image/png"
    assert output["name"] == "out-0.png"

    # Client view: signed URL on the public base, no internal fields.
    view = Jobs.view(job)
    assert [%{"url" => url, "bytes" => _, "sha256" => _, "content_type" => "image/png"}] = view["outputs"]
    assert url =~ ~r|^http://gateway\.test/v1/files/#{job["id"]}/out-0\.png\?exp=\d+&sig=[0-9a-f]{64}$|
    assert view["metadata"] == %{"order" => 7}
    refute Map.has_key?(view, "key_sha256")
    refute Map.has_key?(view, "run")

    # Billed once, in the same ledger as text usage.
    assert job["cost_usd"] == 0.25
    job = await(job["id"], &(&1["ledgered"] == true))
    totals = Ledger.totals(key)
    assert totals.jobs == 1 and totals.requests == 1
    assert_in_delta totals.cost_usd, 0.25, 1.0e-9
    assert {:ok, %{accepted: 0, duplicates: 1}} = Ledger.record_media(%{"id" => job["id"], "key_sha256" => key, "status" => 200, "cost_usd" => 0.25})
    assert Ledger.totals(key).jobs == 1

    # Webhook: two failures, then delivered; every attempt validly signed.
    job = await(job["id"], &(&1["webhook"]["status"] == "delivered"))
    assert job["webhook"]["attempts"] == 3
    assert job["webhook"]["last_status"] == 200
    hooks = Stub.hooks()
    assert length(hooks) == 3

    for hook <- hooks do
      assert hook.id == "msg_" <> job["id"]
      assert hook.signature == Webhooks.signature(@secret, hook.id, hook.timestamp, hook.body)
      payload = JSON.decode!(hook.body)
      assert payload["type"] == "job.succeeded"
      assert payload["data"]["id"] == job["id"]
      assert [%{"url" => _}] = payload["data"]["outputs"]
    end
  end

  test "a job fails only when every target fails, and costs nothing", %{key: key} do
    job = create!(key, %{"model" => "img-bad", "input" => %{}}) |> Map.fetch!("id") |> await()

    assert job["status"] == "failed"
    assert job["error"]["type"] == "all_targets_failed"

    assert [
             %{"upstream" => "nokey", "outcome" => "missing_api_key_env:OMNIGATE_TEST_UNSET_ENV"},
             %{"upstream" => "bad", "outcome" => "provider_failed: boom"}
           ] = job["attempts"]

    assert job["outputs"] == []
    await(job["id"], &(&1["ledgered"] == true))
    totals = Ledger.totals(key)
    assert totals.cost_usd == 0.0 and totals.errors == 1 and totals.jobs == 1
  end

  test "an idempotency key returns the same job without a second submit", %{key: key} do
    params = %{"model" => "img-good", "input" => %{"prompt" => "x"}}
    {:ok, first} = Jobs.create(key, params, "order-1")
    assert {:existing, again} = Jobs.create(key, params, "order-1")
    assert again["id"] == first["id"]
    await(first["id"])
    assert {:existing, _} = Jobs.create(key, params, "order-1")
    assert Stub.count({"good", :submit}) == 1

    # Same key, different request: refused rather than silently ignored.
    assert {:error, 409, "idempotency_conflict", _} = Jobs.create(key, put_in(params, ["input", "prompt"], "y"), "order-1")
    # Another gateway key may reuse the idempotency key.
    assert {:ok, other} = Jobs.create(key <> "-other", params, "order-1")
    refute other["id"] == first["id"]
  end

  test "an identical job is served from cache: no provider call, no cost", %{key: key} do
    params = %{"model" => "tts", "input" => %{"text" => "hello there", "voice_id" => "v1"}}
    first = create!(key, params) |> Map.fetch!("id") |> await()
    assert first["status"] == "succeeded" and first["cached"] == false
    assert_in_delta first["cost_usd"], 0.11, 1.0e-9
    assert Stub.count(:tts_call) == 1

    # Key order in the input does not matter; another gateway key also hits.
    {:ok, second} = Jobs.create(key <> "-b", %{"model" => "tts", "input" => %{"voice_id" => "v1", "text" => "hello there"}})
    assert second["status"] == "succeeded"
    assert second["cached"] == true
    assert second["cost_usd"] == 0.0
    assert Stub.count(:tts_call) == 1
    assert [%{"sha256" => sha}] = second["outputs"]
    assert sha == hd(first["outputs"])["sha256"]
    # The cached job owns its own copy of the file.
    assert File.read!(Path.join([Application.fetch_env!(:omnigate_control, :media_dir), second["id"], "out-0.mp3"])) == "MP3:v1:hello there"

    # Different input: a real call.
    create!(key, put_in(params, ["input", "text"], "something else")) |> Map.fetch!("id") |> await()
    assert Stub.count(:tts_call) == 2

    # Opting out per request.
    third = create!(key, Map.put(params, "cache", false)) |> Map.fetch!("id") |> await()
    assert third["cached"] == false
    assert Stub.count(:tts_call) == 3
  end

  test "cache: true opts in on a route without a cache TTL", %{key: key} do
    params = %{"model" => "img-sync", "input" => %{"prompt" => "p#{System.unique_integer([:positive])}"}}
    first = create!(key, params) |> Map.fetch!("id") |> await()
    assert first["status"] == "succeeded"
    assert hd(first["outputs"])["content_type"] == "image/png"

    not_cached = create!(key, params) |> Map.fetch!("id") |> await()
    assert not_cached["cached"] == false
    assert Stub.count(:image_call) == 2

    {:ok, cached} = Jobs.create(key, Map.put(params, "cache", true))
    assert cached["cached"] == true
    assert Stub.count(:image_call) == 2
  end

  test "a restarted job with a provider id resumes polling instead of resubmitting", %{key: key} do
    # State as a crash would leave it: running, provider job already created.
    now = System.os_time(:millisecond)

    {:ok, job} =
      Store.create(%{
        "id" => "job_resume#{System.unique_integer([:positive])}",
        "status" => "running",
        "model" => "img-good",
        "input" => %{"prompt" => "resume"},
        "outputs" => [],
        "attempts" => [],
        "webhook" => nil,
        "key_sha256" => key,
        "created_ms" => now,
        "created_at" => Store.now_iso(),
        "ledgered" => false,
        "run" => %{"target_index" => 0, "provider_id" => "good-preexisting", "provider_state" => %{}, "attempt_started_ms" => now}
      })

    Runner.run(job["id"])
    job = Store.get(job["id"])
    assert job["status"] == "succeeded"
    assert Stub.count({"good", :submit}) == 0
    assert Stub.count({:poll, "good-preexisting"}) >= 2
    assert File.read!(Path.join([Application.fetch_env!(:omnigate_control, :media_dir), job["id"], "out-0.png"])) =~ "good-preexisting"
  end

  test "jobs, idempotency keys and pending webhooks survive a store restart", %{key: key, base: base} do
    # First delivery fails; the retry is far enough away to restart in between.
    Stub.put(:hook_failures, 1)
    media = ConfigStore.get().media
    ConfigStore.put_media(put_in(media.webhooks.retry_schedule_ms, [400]))

    {:ok, job} = Jobs.create(key, %{"model" => "img-good", "input" => %{"prompt" => "durable"}, "webhook_url" => base <> "/hook"}, "idem-durable")
    job = await(job["id"], &(&1["webhook"]["status"] == "retrying"))
    assert job["webhook"]["attempts"] == 1 and job["webhook"]["last_status"] == 500

    # Simulate a restart: drop every in-memory structure and replay the log.
    for child <- [OmnigateControl.Webhooks, OmnigateControl.Jobs.Store] do
      :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, child)
    end

    assert :ets.whereis(:omnigate_jobs) == :undefined
    {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, OmnigateControl.Jobs.Store)
    {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, OmnigateControl.Webhooks)

    replayed = Store.get(job["id"])
    assert replayed["status"] == "succeeded"
    assert replayed["outputs"] == job["outputs"]
    assert replayed["webhook"]["status"] == "retrying"
    assert {:existing, %{"id" => id}} = Jobs.create(key, %{"model" => "img-good", "input" => %{"prompt" => "durable"}, "webhook_url" => base <> "/hook"}, "idem-durable")
    assert id == job["id"]
    assert Stub.count({"good", :submit}) == 1

    # Boot-time resume re-arms the webhook; it is delivered exactly once more.
    Jobs.resume_all()
    delivered = await(job["id"], &(&1["webhook"]["status"] == "delivered"))
    assert delivered["webhook"]["attempts"] == 2
    assert length(Stub.hooks()) == 2
    # The ledger was not charged again by the resume.
    assert Ledger.totals(key).jobs == 1
  end

  test "a webhook that never succeeds stops after max_attempts", %{key: key, base: base} do
    Stub.put(:hook_failures, 99)
    {:ok, job} = Jobs.create(key, %{"model" => "img-good", "input" => %{}, "webhook_url" => base <> "/hook"})
    job = await(job["id"], &(&1["webhook"]["status"] == "failed"))
    assert job["webhook"]["attempts"] == 4
    assert job["webhook"]["last_error"] == "http_500"
    assert length(Stub.hooks()) == 4
    # The job itself still succeeded.
    assert job["status"] == "succeeded"
  end

  test "cancel stops a running job and tells the provider", %{key: key} do
    Stub.put(:polls_needed, 1_000_000)
    {:ok, job} = Jobs.create(key, %{"model" => "img-good", "input" => %{}})
    await(job["id"], &is_binary(get_in(&1, ["run", "provider_id"])))

    assert %{"status" => "canceled"} = Jobs.cancel(key, job["id"])
    Process.sleep(100)
    assert Stub.count({"good", :cancel}) >= 1
    assert Store.get(job["id"])["status"] == "canceled"
    # Canceling again, or a late runner result, changes nothing.
    assert %{"status" => "canceled"} = Jobs.cancel(key, job["id"])
    assert Jobs.finish(job["id"], "succeeded", %{}) == :noop
    assert Jobs.cancel("someone-else", job["id"]) == nil
  end

  test "validation: unknown model, bad input, webhook URL checks", %{key: key} do
    assert {:error, 404, "model_not_found", _} = Jobs.create(key, %{"model" => "nope", "input" => %{}})
    assert {:error, 400, "missing_model", _} = Jobs.create(key, %{"input" => %{}})
    assert {:error, 400, "invalid_request", _} = Jobs.create(key, %{"model" => "img", "input" => "text"})
    assert {:error, 400, "invalid_request", _} = Jobs.create(key, %{"model" => "img"})
    assert {:error, 400, "invalid_webhook_url", _} = Jobs.create(key, %{"model" => "img", "input" => %{}, "webhook_url" => "ftp://x/y"})

    media = ConfigStore.get().media
    ConfigStore.put_media(put_in(media.webhooks.allow_private, false))
    assert {:error, "webhook_url resolves to a private or loopback address"} = Webhooks.check_url("http://127.0.0.1:9/hook")
    assert {:error, _} = Webhooks.check_url("http://10.1.2.3/hook")
    assert {:error, _} = Webhooks.check_url("http://169.254.169.254/latest/meta-data")
    assert {:error, _} = Webhooks.check_url("http://[::1]/hook")
    assert {:error, _} = Webhooks.check_url("http://user:pw@example.com/hook")
    assert {:error, 400, "invalid_webhook_url", _} = Jobs.create(key, %{"model" => "img", "input" => %{}, "webhook_url" => "http://127.0.0.1:9/hook"})

    ConfigStore.put_media(put_in(media.webhooks.secret, nil))
    assert {:error, 400, "webhook_not_configured", _} = Jobs.create(key, %{"model" => "img", "input" => %{}, "webhook_url" => "http://127.0.0.1:9/hook"})
  end

  describe "HTTP API" do
    # A real gateway key from the dev config, as the data plane would name it.
    @key OmnigateControl.sha256_hex("og-unlimited-key")
    @other OmnigateControl.sha256_hex("og-ratelimited-key")

    defp call(method, path, body \\ nil, headers \\ []) do
      conn =
        case body do
          nil -> conn(method, path)
          _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
        end

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      conn = Router.call(conn, Router.init([]))
      body = if conn.resp_body in [nil, ""], do: nil, else: conn.resp_body
      {conn.status, body, conn}
    end

    defp internal(key \\ @key), do: [{"x-omnigate-internal", @token}] ++ if(key, do: [{"x-omnigate-key-sha256", key}], else: [])
    defp json({status, body, _conn}), do: {status, JSON.decode!(body)}

    test "create, read, list, cancel and download through the router" do
      assert {401, _} = call(:post, "/internal/v1/jobs", %{"model" => "img-good", "input" => %{}}) |> json()
      assert {401, %{"error" => %{"type" => "invalid_api_key"}}} = call(:post, "/internal/v1/jobs", %{"model" => "img-good", "input" => %{}}, internal("deadbeef")) |> json()
      assert {404, %{"error" => %{"type" => "model_not_found"}}} = call(:post, "/internal/v1/jobs", %{"model" => "nope", "input" => %{}}, internal()) |> json()

      idem = [{"idempotency-key", "http-#{System.unique_integer([:positive])}"}]
      assert {202, created} = call(:post, "/internal/v1/jobs", %{"model" => "img-good", "input" => %{"prompt" => "via http"}}, internal() ++ idem) |> json()
      assert created["object"] == "job" and created["status"] in ["queued", "running"]
      assert {200, %{"id" => same}} = call(:post, "/internal/v1/jobs", %{"model" => "img-good", "input" => %{"prompt" => "via http"}}, internal() ++ idem) |> json()
      assert same == created["id"]
      assert {409, _} = call(:post, "/internal/v1/jobs", %{"model" => "img-good", "input" => %{"prompt" => "changed"}}, internal() ++ idem) |> json()

      await(created["id"])
      assert {200, job} = call(:get, "/internal/v1/jobs/#{created["id"]}", nil, internal()) |> json()
      assert job["status"] == "succeeded"
      assert {404, _} = call(:get, "/internal/v1/jobs/#{created["id"]}", nil, internal(@other)) |> json()

      assert {200, %{"object" => "list", "data" => [%{"id" => newest} | _]}} = call(:get, "/internal/v1/jobs?limit=1", nil, internal()) |> json()
      assert newest == created["id"]
      assert {200, %{"data" => others}} = call(:get, "/internal/v1/jobs", nil, internal(@other)) |> json()
      refute Enum.any?(others, &(&1["id"] == created["id"]))

      # Download: signed URL with no key, owner key with no signature.
      [%{"url" => url, "sha256" => sha}] = job["outputs"]
      %URI{path: path, query: query} = URI.parse(url)
      internal_path = "/internal" <> path

      assert {200, bytes, conn} = call(:get, internal_path <> "?" <> query, nil, internal(nil))
      assert OmnigateControl.sha256_hex(bytes) == sha
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert {200, ^bytes, _} = call(:get, internal_path, nil, internal())
      assert {404, _, _} = call(:get, internal_path, nil, internal(@other))
      assert {401, _, _} = call(:get, internal_path, nil, internal(nil))
      assert {403, _, _} = call(:get, internal_path <> "?" <> String.replace(query, ~r/sig=../, "sig=00"), nil, internal(nil))
      assert {403, _, _} = call(:get, internal_path <> "?exp=1&sig=" <> String.duplicate("0", 64), nil, internal(nil))
      assert {404, _, _} = call(:get, "/internal/v1/files/#{created["id"]}/..%2F..%2Fsecret?" <> query, nil, internal())
      # Without the internal token nothing is reachable.
      assert {401, _, _} = call(:get, internal_path <> "?" <> query, nil, [])

      assert {200, %{"status" => "succeeded"}} = call(:post, "/internal/v1/jobs/#{created["id"]}/cancel", nil, internal()) |> json()
      assert {404, _} = call(:post, "/internal/v1/jobs/#{created["id"]}/cancel", nil, internal(@other)) |> json()

      # The dashboard lists the job.
      assert {200, html, _} = call(:get, "/")
      assert html =~ created["id"]
    end

    test "a key over budget cannot create jobs" do
      dev = OmnigateControl.sha256_hex("og-dev-key")
      {:ok, _} = Ledger.record_media(%{"id" => "job_budget#{System.unique_integer([:positive])}", "key_sha256" => dev, "status" => 200, "cost_usd" => 5.0})
      assert {402, %{"error" => %{"type" => "budget_exceeded"}}} = call(:post, "/internal/v1/jobs", %{"model" => "img-good", "input" => %{}}, internal(dev)) |> json()
    end
  end
end
