defmodule OmnigateControl.Wave4Test.Provider do
  @moduledoc """
  A Replicate-style provider that can misbehave: it reports whatever output
  URL the test tells it to, redirects on request, and has a `/secret` that
  stands for something on the internal network and counts who reached it.
  """
  use Plug.Router

  @table :omnigate_wave4_stub

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"])
  plug(:dispatch)

  def setup do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    :ets.delete_all_objects(@table)
  end

  def put(key, value), do: :ets.insert(@table, {key, value})

  def count(name) do
    case :ets.lookup(@table, {:count, name}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  defp bump(name), do: :ets.update_counter(@table, {:count, name}, 1, {{:count, name}, 0})

  defp val(key, default) do
    case :ets.lookup(@table, key) do
      [{_, v}] -> v
      [] -> default
    end
  end

  defp base(conn), do: "http://127.0.0.1:#{conn.port}"

  post "/v1/models/:owner/:name/predictions" do
    bump(:submit)
    send_json(conn, 201, %{id: "p-#{System.unique_integer([:positive])}", status: "starting", output: nil})
  end

  get "/v1/predictions/:id" do
    polls = bump({:poll, id})

    if polls < val(:polls_needed, 2) do
      send_json(conn, 200, %{id: id, status: "processing", output: nil})
    else
      send_json(conn, 200, %{id: id, status: "succeeded", output: val(:output_url, "#{base(conn)}/files/#{id}.png")})
    end
  end

  post "/v1/predictions/:id/cancel" do
    send_json(conn, 200, %{id: id, status: "canceled"})
  end

  get "/files/:name" do
    bump(:download)
    conn |> put_resp_header("content-type", val(:file_type, "image/png")) |> send_resp(200, "FILE-" <> name)
  end

  get "/redirect" do
    bump(:redirect)
    conn |> put_resp_header("location", val(:redirect_to, "/secret")) |> send_resp(302, "")
  end

  get "/loop" do
    conn |> put_resp_header("location", "/loop") |> send_resp(302, "")
  end

  get "/secret" do
    bump(:secret)
    send_resp(conn, 200, "internal-only")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp send_json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end

defmodule OmnigateControl.Wave4SecurityTest do
  # Not async: jobs, keys, the ledger and the config are shared named processes.
  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{AdminAuth, ConfigStore, Http, Jobs, Keys, NetGuard, RateLimit, Router}
  alias OmnigateControl.Jobs.{Adapter, Store}
  alias OmnigateControl.Jobs.Adapters
  alias OmnigateControl.Ledger.Files
  alias OmnigateControl.Wave4Test.Provider

  @admin "test-admin-token-0123456789"

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Provider, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("OMNIGATE_TEST_PROVIDER_KEY", "provider-secret")
    original = ConfigStore.get().media
    on_exit(fn -> ConfigStore.put_media(original) end)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  setup %{base: base} do
    wait_idle()
    Provider.setup()
    put_media(base, true)
    :ok
  end

  defp put_media(base, allow_private, extra \\ %{}) do
    price = %{per_job_usd: 0.0, per_output_usd: 0.25, per_input_char_usd: 0.0, per_second_usd: 0.0}

    ConfigStore.put_media(
      Map.merge(
        %{
          public_base_url: "http://gateway.test",
          poll_interval_ms: 10,
          max_output_bytes: 1_000_000,
          max_input_bytes: 1_048_576,
          max_open_jobs: 100,
          upstreams: [%{name: "prov", kind: "replicate", base_url: base, api_key_env: "OMNIGATE_TEST_PROVIDER_KEY"}],
          routes: [%{model: "img", cache_ttl_s: nil, timeout_s: 30, targets: [%{upstream: "prov", model: "owner/model", price: price}]}],
          storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600},
          webhooks: %{retry_schedule_ms: [30], max_attempts: 2, timeout_ms: 2_000, allow_private: allow_private, secret: "s"}
        },
        extra
      )
    )
  end

  defp wait_idle(tries \\ 500) do
    busy = Enum.reject(Store.all(), &Jobs.terminal?/1)

    cond do
      busy == [] -> :ok
      tries == 0 -> Enum.each(busy, &Jobs.finish(&1["id"], "canceled", %{}))
      true -> Process.sleep(10) && wait_idle(tries - 1)
    end
  end

  defp await(id, pred \\ &Jobs.terminal?/1, tries \\ 400) do
    job = Store.get(id)

    cond do
      pred.(job) -> job
      tries == 0 -> flunk("timed out waiting for job #{id}: #{inspect(job)}")
      true -> Process.sleep(10) && await(id, pred, tries - 1)
    end
  end

  defp key, do: "key-#{System.unique_integer([:positive])}"
  defp call(conn), do: Router.call(conn, Router.init([]))
  defp internal(conn, hash), do: conn |> put_req_header("x-omnigate-internal", OmnigateControl.internal_token()) |> with_key(hash)
  defp with_key(conn, nil), do: conn
  defp with_key(conn, hash), do: put_req_header(conn, "x-omnigate-key-sha256", hash)
  defp json(conn), do: JSON.decode!(conn.resp_body)

  defp post_job(hash, body, path \\ "/internal/v1/jobs") do
    conn(:post, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json") |> internal(hash) |> call()
  end

  defp managed_key(attrs) do
    name = "w4-#{System.unique_integer([:positive])}"
    {:ok, key, _raw} = Keys.create(Map.put(attrs, "name", name))
    on_exit(fn -> Keys.delete(name) end)
    key
  end

  # ---------------------------------------------------------------- finding 1

  describe "router guards see the path the router dispatches on" do
    test "odd spellings of protected paths are never served without credentials" do
      for {method, path, expected} <- [
            {:get, "//admin//keys", [401, 404]},
            {:get, "/admin/keys/", 401},
            {:get, "/admin/", 401},
            {:get, "/admin", 401},
            {:head, "/admin/keys", 401},
            {:get, "/ADMIN/keys", 404},
            {:get, "/Admin/Keys", 404},
            {:get, "/admin;x/keys", 404},
            {:get, "/metrics/", 401},
            {:get, "//metrics", [400, 401, 404]},
            {:get, "/internal/config/", 401},
            {:get, "//internal//config", [401, 404]},
            {:get, "/INTERNAL/config", 404},
            {:get, "/./admin/keys", 400},
            {:get, "/x/../admin/keys", 400},
            {:get, "/admin%2fkeys", 400},
            {:get, "/%2e%2e/admin/keys", 400},
            {:get, "/debug", 404},
            {:post, "/admin/keys/", 401},
            {:delete, "/admin/keys/main", 401},
            {:patch, "/admin/keys/main/", 401}
          ] do
        conn = conn(method, path) |> call()
        # Doubled slashes are split differently by different HTTP servers; either refusal is right.
        assert conn.status in List.wrap(expected), "#{method} #{path} answered #{conn.status}, expected #{inspect(expected)}"
        refute conn.resp_body =~ "key_sha256"
        refute conn.resp_body =~ ~s("keys":[)
      end
    end

    test "the internal token opens only /internal, the admin token only the admin side" do
      as_internal = fn path -> conn(:get, path) |> put_req_header("x-omnigate-internal", OmnigateControl.internal_token()) |> call() end
      as_admin = fn path -> conn(:get, path) |> put_req_header("authorization", "Bearer " <> @admin) |> call() end

      assert as_internal.("/internal/config").status == 200
      assert as_internal.("/internal/config/").status == 200
      for path <- ["/admin/keys", "/admin/overview", "/metrics", "/admin/audit"], do: assert(as_internal.(path).status == 401)

      assert as_admin.("/admin/keys").status == 200
      assert as_admin.("/internal/config").status == 401
    end

    test "an anonymous caller cannot make the login endpoint parse a large body" do
      big = "password=" <> String.duplicate("a", 10_000)

      conn =
        conn(:post, "/login", big) |> put_req_header("content-type", "application/x-www-form-urlencoded") |> put_req_header("content-length", "10009") |> call()

      assert conn.status == 413
      assert %{"error" => %{"type" => "payload_too_large"}} = json(conn)

      # A normal login form still goes through to the password check.
      ok =
        conn(:post, "/login", "password=nope") |> put_req_header("content-type", "application/x-www-form-urlencoded") |> put_req_header("content-length", "13")

      assert (ok |> Map.put(:remote_ip, {10, 44, 0, 1}) |> call()).status == 401
    end
  end

  # ---------------------------------------------------------------- finding 5

  describe "job creation limits enforced in the control plane" do
    test "the key's requests-per-minute limit applies, whatever spelling of the path is used" do
      key = managed_key(%{"rpm" => 2})
      RateLimit.reset(key.name)
      body = %{"model" => "img", "input" => %{"prompt" => "x"}}

      assert post_job(key.key_sha256, body).status == 202
      # The trailing slash that slipped past the data plane's check is the same route here.
      assert post_job(key.key_sha256, body, "/internal/v1/jobs/").status == 202

      refused = post_job(key.key_sha256, body, "/internal/v1/jobs/")
      assert refused.status == 429
      assert %{"error" => %{"type" => "rate_limit_exceeded"}} = json(refused)
      assert [retry] = get_resp_header(refused, "retry-after")
      assert String.to_integer(retry) in 1..60
      assert post_job(key.key_sha256, body).status == 429
    end

    test "the rate limiter counts per key and per minute" do
      id = "rl-#{System.unique_integer([:positive])}"
      now = 1_800_000_000 - rem(1_800_000_000, 60)
      assert :ok = RateLimit.check(id, 2, now)
      assert :ok = RateLimit.check(id, 2, now + 10)
      assert {:error, 30} = RateLimit.check(id, 2, now + 30)
      assert :ok = RateLimit.check(id <> "-other", 2, now + 30)
      # The next minute starts fresh; no limit means no counting.
      assert :ok = RateLimit.check(id, 2, now + 60)
      for _ <- 1..50, do: assert(:ok = RateLimit.check(id, 0, now))
      for _ <- 1..50, do: assert(:ok = RateLimit.check(id, nil, now))
    end

    test "a key cannot hold more unfinished jobs than its cap" do
      key = managed_key(%{"max_open_jobs" => 2})
      Provider.put(:polls_needed, 1_000_000)
      body = %{"model" => "img", "input" => %{"prompt" => "slow"}}

      first = post_job(key.key_sha256, body)
      second = post_job(key.key_sha256, body)
      assert first.status == 202 and second.status == 202
      assert Store.open_count(Keys.hashes(key)) == 2

      third = post_job(key.key_sha256, body)
      assert third.status == 429
      assert %{"error" => %{"type" => "too_many_open_jobs"}} = json(third)
      assert get_resp_header(third, "retry-after") != []
      assert Provider.count(:submit) <= 2

      # Another key is not affected, and finishing a job frees a slot.
      other = managed_key(%{})
      assert post_job(other.key_sha256, body).status == 202

      {:ok, _} = Jobs.finish(json(first)["id"], "canceled", %{})
      assert Store.open_count(Keys.hashes(key)) == 1
      assert post_job(key.key_sha256, body).status == 202
      wait_idle(0)
    end

    test "the cap falls back to the media default and survives a rotation" do
      key = managed_key(%{})
      assert Keys.max_open_jobs(key) == 100
      {:ok, patched} = Keys.update(key.name, %{"max_open_jobs" => 1})
      assert Keys.max_open_jobs(patched) == 1
      assert {:error, 400, "invalid_request", _} = Keys.update(key.name, %{"max_open_jobs" => -1})

      Provider.put(:polls_needed, 1_000_000)
      assert post_job(patched.key_sha256, %{"model" => "img", "input" => %{"prompt" => "a"}}).status == 202
      {:ok, rotated, _raw} = Keys.rotate(key.name)
      # The job created under the old secret still counts against the key.
      assert post_job(rotated.key_sha256, %{"model" => "img", "input" => %{"prompt" => "b"}}).status == 429
      wait_idle(0)
    end
  end

  # ---------------------------------------------------------------- finding 7

  describe "billing follows what is sent to the provider" do
    @price %{per_job_usd: 0.01, per_output_usd: 0.002, per_input_char_usd: 0.0001, per_second_usd: 0.1}

    test "a negative or non-numeric duration or count is refused when the job is submitted" do
      for input <- [
            %{"seconds" => -1_000_000},
            %{"duration" => -1},
            %{"duration" => "-5"},
            %{"duration" => "abc"},
            %{"seconds" => [5]},
            %{"n" => -1},
            %{"num_outputs" => 1.5},
            %{"num_images" => "2"}
          ] do
        assert {:error, 400, "invalid_request", message} = Jobs.create(key(), %{"model" => "img", "input" => Map.put(input, "prompt", "x")})
        assert message =~ "must be"
      end

      assert Provider.count(:submit) == 0

      # Plain and textual numbers are fine (some providers take "5").
      for input <- [%{"duration" => 5}, %{"duration" => "5"}, %{"seconds" => 2.5}, %{"n" => 2}, %{"duration" => 0}] do
        assert {:ok, job} = Jobs.create(key(), %{"model" => "img", "input" => Map.put(input, "prompt", "x")})
        await(job["id"])
      end
    end

    test "no component of the price can lower another" do
      assert_in_delta Jobs.cost(@price, %{chars: 5, seconds: 5}, 2), 0.01 + 2 * 0.002 + 5 * 0.0001 + 5 * 0.1, 1.0e-12
      # A negative quantity (which validation refuses, and adapters never report) counts as nothing.
      assert_in_delta Jobs.cost(@price, %{chars: 5, seconds: -1_000_000}, 2), 0.01 + 2 * 0.002 + 5 * 0.0001, 1.0e-12
      assert_in_delta Jobs.cost(@price, %{chars: -100, seconds: 0}, -3), 0.01, 1.0e-12
      assert_in_delta Jobs.cost(@price, %{}, 0), 0.01, 1.0e-12
      assert Jobs.cost(%{@price | per_job_usd: -5.0}, %{chars: 0, seconds: 0}, 0) == 0.0
    end

    test "the Gemini adapter is billed for the text it sends, not for a decoy field" do
      long = String.duplicate("word ", 200)
      # It sends `prompt` in preference to `text`; billing used to count `text`.
      assert {:ok, body} = Adapters.Gemini.request_body(%{"text" => "a", "prompt" => long})
      assert get_in(body, ["contents", Access.at(0), "parts", Access.at(0), "text"]) == long
      assert Adapters.Gemini.billable(%{"text" => "a", "prompt" => long}) == %{chars: String.length(long), seconds: 0}

      # The native form used to be free per character.
      native = %{"contents" => [%{"parts" => [%{"text" => "hello"}, %{"inlineData" => %{"data" => "QUJD"}}]}, %{"parts" => [%{"text" => "world!"}]}]}
      assert Adapters.Gemini.billable(native) == %{chars: 11, seconds: 0}
      assert Adapters.Gemini.billable(Map.put(native, "systemInstruction", %{"parts" => [%{"text" => "abc"}]})).chars == 14

      assert Adapters.GeminiInteractions.billable(%{"prompt" => "hello"}) == %{chars: 5, seconds: 0}
      assert Adapters.GeminiInteractions.billable(%{"input" => "hello there"}).chars == 11
      assert Adapters.GeminiInteractions.billable(%{"input" => [%{"type" => "text", "text" => "abcd"}, %{"type" => "image", "data" => "QUJD"}]}).chars == 4
    end

    test "adapters that forward the whole input count every text field and the larger duration" do
      input = %{"prompt" => "abc", "text" => "defgh", "duration" => 2, "seconds" => "7", "other" => "ignored"}

      for adapter <- [Adapters.Replicate, Adapters.Fal, Adapters.XaiVideo] do
        assert adapter.billable(input) == %{chars: 8, seconds: 7.0}
        assert adapter.billable(%{}) == %{chars: 0, seconds: 0}
      end

      assert Adapters.ElevenLabs.billable(%{"text" => "hello", "prompt" => String.duplicate("x", 500)}) == %{chars: 5, seconds: 0}
      assert Adapters.OpenAIImages.billable(%{"prompt" => "a cube", "duration" => 99}) == %{chars: 6, seconds: 0}
      assert Adapter.seconds(%{"duration" => -5, "seconds" => "junk"}, ~w(duration seconds)) == 0
    end

    test "every adapter kind implements billable/1" do
      for kind <- Adapter.kinds() do
        module = Adapter.for_kind(kind)
        assert %{chars: chars, seconds: seconds} = apply(module, :billable, [%{"prompt" => "p", "text" => "t", "input" => "i"}])
        assert is_integer(chars) and chars >= 0 and is_number(seconds) and seconds >= 0
      end
    end

    test "a finished job is priced from the adapter's quantities" do
      base = ConfigStore.get().media
      price = %{per_job_usd: 0.0, per_output_usd: 0.0, per_input_char_usd: 0.01, per_second_usd: 1.0}
      ConfigStore.put_media(%{base | routes: [%{hd(base.routes) | targets: [%{upstream: "prov", model: "owner/model", price: price}]}]})

      {:ok, job} = Jobs.create(key(), %{"model" => "img", "input" => %{"prompt" => "abcd", "text" => "ef", "duration" => 3}})
      job = await(job["id"])
      assert job["status"] == "succeeded"
      # 6 characters sent, 3 seconds asked for.
      assert_in_delta job["cost_usd"], 6 * 0.01 + 3 * 1.0, 1.0e-9
    end

    test "media prices must not be negative" do
      bad = %{"media" => %{"routes" => [%{"model" => "m", "targets" => [%{"upstream" => "u", "model" => "x", "price" => %{"per_second_usd" => -1}}]}]}}
      assert_raise ArgumentError, ~r/price must be a number of dollars, 0 or more/, fn -> ConfigStore.normalize(bad) end
    end

    test "an oversized job input is refused" do
      big = %{"prompt" => String.duplicate("a", 1_100_000)}
      assert {:error, 413, "payload_too_large", _} = Jobs.create(key(), %{"model" => "img", "input" => big})
      assert {:error, 413, "payload_too_large", _} = Jobs.create(key(), %{"model" => "img", "input" => %{"prompt" => "x"}, "metadata" => big})
      assert Provider.count(:submit) == 0
      assert ConfigStore.normalize(%{}).media.max_input_bytes == 1_048_576
      assert ConfigStore.normalize(%{"media" => %{"max_input_bytes" => 10, "max_open_jobs" => 0}}).media.max_open_jobs == 0
    end
  end

  # ---------------------------------------------------------------- finding 8

  describe "provider output URLs" do
    test "an output URL on a private address is not fetched", %{base: base} do
      put_media(base, false)

      for url <- [base <> "/secret", "http://169.254.169.254/latest/meta-data/", "http://[::1]:1/x", "http://[::ffff:10.0.0.1]/x", "http://0x7f000001/x"] do
        Provider.put(:output_url, url)
        {:ok, job} = Jobs.create(key(), %{"model" => "img", "input" => %{"prompt" => "x"}})
        job = await(job["id"])
        assert job["status"] == "failed", url
        assert [%{"outcome" => outcome}] = job["attempts"]
        assert outcome =~ "output_fetch_failed: blocked: output url", "#{url}: #{outcome}"
        assert job["outputs"] == []
      end

      assert Provider.count(:secret) == 0
      assert Provider.count(:download) == 0
    end

    test "with private addresses allowed (local mocks), the same job succeeds", %{base: base} do
      put_media(base, true)
      {:ok, job} = Jobs.create(key(), %{"model" => "img", "input" => %{"prompt" => "x"}})
      assert await(job["id"])["status"] == "succeeded"
      assert Provider.count(:download) == 1
    end

    test "every redirect hop goes through the guard, and nothing is fetched from a refused one", %{base: base} do
      dest = Path.join(System.tmp_dir!(), "omnigate-w4-dl-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)
      seen = :ets.new(:seen, [:public, :bag])

      # A guard that lets the provider's own URL through but nothing it redirects to.
      guard = fn url ->
        :ets.insert(seen, {:url, url})
        if String.ends_with?(url, "/redirect"), do: {:ok, {127, 0, 0, 1}}, else: {:error, "not allowed here"}
      end

      Provider.put(:redirect_to, "/secret")
      assert {:error, "blocked: not allowed here"} = Http.download(base <> "/redirect", dest, 1_000, guard: guard)
      assert Provider.count(:redirect) == 1
      assert Provider.count(:secret) == 0
      refute File.exists?(dest)
      assert [base <> "/redirect", base <> "/secret"] == seen |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

      # An absolute redirect to another host is judged on that host.
      Provider.put(:redirect_to, "http://169.254.169.254/latest/meta-data/")

      assert {:error, "blocked: output url resolves to a private or loopback address"} =
               Http.download(base <> "/redirect", dest, 1_000,
                 guard: fn url -> if url =~ "/redirect", do: {:ok, {127, 0, 0, 1}}, else: without_private(fn -> NetGuard.target(url, "output url") end) end
               )
    end

    test "allowed redirects are followed, up to a limit", %{base: base} do
      dest = Path.join(System.tmp_dir!(), "omnigate-w4-dl-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)
      allow = fn _url -> {:ok, {127, 0, 0, 1}} end

      Provider.put(:redirect_to, "/files/a.png")
      assert {:ok, %{bytes: 10, content_type: "image/png"}} = Http.download(base <> "/redirect", dest, 1_000, guard: allow)
      assert File.read!(dest) == "FILE-a.png"

      assert {:error, "too many redirects"} = Http.download(base <> "/loop", dest, 1_000, guard: allow)
      assert {:error, "too many redirects"} = Http.download(base <> "/redirect", dest, 1_000, guard: allow, max_redirects: 0)
      # The size cap still applies.
      assert {:error, :output_too_large} = Http.download(base <> "/files/a.png", dest, 5, guard: allow)
    end

    defp without_private(fun) do
      media = ConfigStore.get().media
      ConfigStore.put_media(%{media | webhooks: %{media.webhooks | allow_private: false}})

      try do
        fun.()
      after
        ConfigStore.put_media(media)
      end
    end
  end

  describe "the address filter" do
    test "refuses every special-purpose range" do
      private = ~w(
        0.0.0.0 10.1.2.3 100.64.0.1 100.127.255.255 127.0.0.1 169.254.169.254 172.16.0.1 172.31.255.255
        192.0.0.1 192.0.0.170 192.0.2.1 192.31.196.1 192.52.193.1 192.88.99.1 192.168.1.1 192.175.48.1
        198.18.0.1 198.19.255.255 198.51.100.7 203.0.113.9 224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255
        :: ::1 ::10.0.0.1 ::8.8.8.8 ::ffff:10.0.0.1 ::ffff:127.0.0.1 ::ffff:169.254.169.254
        64:ff9b::10.0.0.1 64:ff9b::7f00:1 64:ff9b:1::1 2002:a00:1:: 2002:7f00:1::1 2002:c0a8:101::
        100::1 2001::1 2001:10::1 2001:20::1 2001:2::1 2001:db8::1 3fff::1 5f00::1
        fc00::1 fd12:3456::1 fe80::1 fec0::1 ff02::1
      )

      for text <- private do
        {:ok, ip} = :inet.parse_address(String.to_charlist(text))
        assert NetGuard.private?(ip), "#{text} should be refused"
      end
    end

    test "lets public addresses through, including ones behind the IPv4-embedding forms" do
      public = ~w(
        1.1.1.1 8.8.8.8 100.63.255.255 100.128.0.1 172.15.255.255 172.32.0.1 192.0.1.1 192.167.255.255 192.169.0.1
        198.17.255.255 198.20.0.1 223.255.255.255
        ::ffff:8.8.8.8 64:ff9b::808:808 2002:808:808::1 2001:4860:4860::8888 2606:4700:4700::1111 2a00:1450::1
      )

      for text <- public do
        {:ok, ip} = :inet.parse_address(String.to_charlist(text))
        refute NetGuard.private?(ip), "#{text} should be allowed"
      end
    end

    test "webhook URLs use the same filter", %{base: base} do
      put_media(base, false)

      for url <- ["http://192.0.0.8/h", "http://198.18.0.1/h", "http://[64:ff9b::a00:1]/h", "http://[2002:a00:1::]/h", "http://[::10.0.0.1]/h"] do
        assert {:error, "webhook_url resolves to a private or loopback address"} = OmnigateControl.Webhooks.check_url(url)
      end

      assert {:error, "webhook_url must be http or https"} = OmnigateControl.Webhooks.check_url("ftp://example.com/x")
      assert {:error, "webhook_url must not contain credentials"} = OmnigateControl.Webhooks.check_url("http://u:p@8.8.8.8/x")
      assert :ok = OmnigateControl.Webhooks.check_url("http://8.8.8.8/h")
    end
  end

  # --------------------------------------------------------------- finding 10

  describe "admin token handling" do
    test "wrong bearer tokens from one address lock that address out for a while" do
      ip = {10, 55, 0, 1}
      previous = Application.get_env(:omnigate_control, :bearer_max_failures)
      Application.put_env(:omnigate_control, :bearer_max_failures, 3)

      on_exit(fn ->
        Application.put_env(:omnigate_control, :bearer_max_failures, previous)
        AdminAuth.clear_bearer_failures(ip)
      end)

      AdminAuth.clear_bearer_failures(ip)

      get = fn path, headers, from ->
        Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end) |> Map.put(:remote_ip, from) |> call()
      end

      # Requests with no token at all are not guesses and never count.
      for _ <- 1..10, do: assert(get.("/admin/keys", [], ip).status == 401)
      assert get.("/admin/keys", [{"authorization", "Bearer " <> @admin}], ip).status == 200

      for path <- ["/admin/keys", "/metrics", "/admin/overview"] do
        assert get.(path, [{"authorization", "Bearer wrong-#{path}"}], ip).status == 401
      end

      # Now even the right token is refused from that address, so guessing cannot continue.
      locked = get.("/admin/keys", [{"authorization", "Bearer " <> @admin}], ip)
      assert locked.status == 429
      assert get_resp_header(locked, "retry-after") == ["60"]
      assert get.("/metrics", [{"authorization", "Bearer " <> @admin}], ip).status == 429

      # Other addresses, and browser sessions, are unaffected.
      assert get.("/admin/keys", [{"authorization", "Bearer " <> @admin}], {10, 55, 0, 2}).status == 200
      session = AdminAuth.issue_session()
      assert get.("/admin/keys", [{"cookie", AdminAuth.cookie_name() <> "=" <> session}], ip).status == 200

      # And the lockout ends by itself.
      refute AdminAuth.bearer_throttled?(ip, System.os_time(:second) + 61)
    end

    test "attempts are counted per peer, or per forwarded address only when that is switched on" do
      peer = {172, 18, 0, 5}

      from = fn headers ->
        Enum.reduce(headers, conn(:get, "/admin/keys"), fn v, c -> prepend_req_headers(c, [{"x-forwarded-for", v}]) end) |> Map.put(:remote_ip, peer)
      end

      # Off (the default): the header is the client's to write, so it is ignored.
      assert AdminAuth.client_address(from.(["203.0.113.9"]), false) == peer
      assert AdminAuth.client_address(from.([]), true) == peer

      # On: the last hop is the one the nearest proxy wrote; earlier ones are the client's claim.
      assert AdminAuth.client_address(from.(["203.0.113.9"]), true) == {203, 0, 113, 9}
      assert AdminAuth.client_address(from.(["1.2.3.4, 203.0.113.9"]), true) == {203, 0, 113, 9}
      assert AdminAuth.client_address(from.(["not an address"]), true) == peer

      # One IPv6 host owns a whole /64: count it as one.
      assert AdminAuth.client_address(from.(["2001:db8:1:2:aaaa:bbbb:cccc:dddd"]), true) == {0x2001, 0xDB8, 1, 2, 0, 0, 0, 0}
      assert AdminAuth.client_address(from.(["2001:db8:1:2::1"]), true) == AdminAuth.client_address(from.(["2001:db8:1:2:ffff::9"]), true)
    end

    test "the table of failed attempts is swept once it has grown" do
      now = System.os_time(:second)
      old = for n <- 1..10_050, do: {:sweep_test, n}
      on_exit(fn -> Enum.each([{:sweep_test, :fresh} | old], &AdminAuth.clear_failures/1) end)

      Enum.each(old, &AdminAuth.note_failure(&1, now - 3600))
      before = :ets.info(:omnigate_login_failures, :size)
      AdminAuth.note_failure({:sweep_test, :fresh}, now)

      assert :ets.info(:omnigate_login_failures, :size) < before - 9_000
      assert :ets.lookup(:omnigate_login_failures, {:sweep_test, :fresh}) != []
    end

    test "an explicitly set admin token must be long enough; an unset one is generated" do
      assert {:error, message} = AdminAuth.resolve_token("short-token")
      assert message =~ "shorter than 16"
      assert {:error, _} = AdminAuth.resolve_token(String.duplicate("a", 15))
      assert {:ok, "0123456789abcdef"} = AdminAuth.resolve_token("0123456789abcdef")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, generated} = AdminAuth.resolve_token(nil)
          assert byte_size(generated) >= 32
          assert {:ok, _} = AdminAuth.resolve_token("")
        end)

      assert log =~ "OMNIGATE_ADMIN_TOKEN is not set"
    end
  end

  describe "startup" do
    test "the development config is never a release's fallback" do
      assert {:ok, "/etc/omnigate.json"} = OmnigateControl.Application.config_path("/etc/omnigate.json", false)
      assert {:error, message} = OmnigateControl.Application.config_path(nil, false)
      assert message =~ "OMNIGATE_CONFIG is not set"
      assert {:error, _} = OmnigateControl.Application.config_path("", false)
      # Only a development or test build falls back to the checked-in dev config.
      assert {:ok, path} = OmnigateControl.Application.config_path(nil, true)
      assert String.ends_with?(path, "omnigate.dev.json")
    end
  end

  describe "stored outputs" do
    test "are served as downloads, never as something a browser would run", %{base: base} do
      for {declared, served} <- [{"text/html", "application/octet-stream"}, {"image/svg+xml", "application/octet-stream"}, {"image/png", "image/png"}] do
        Provider.put(:file_type, declared)
        Provider.put(:output_url, base <> "/files/page.html")
        key = managed_key(%{})
        {:ok, job} = Jobs.create(key.key_sha256, %{"model" => "img", "input" => %{"prompt" => declared}})
        job = await(job["id"])
        assert job["status"] == "succeeded"
        name = hd(job["outputs"])["name"]

        conn = conn(:get, "/internal/v1/files/#{job["id"]}/#{name}") |> internal(key.key_sha256) |> call()
        assert conn.status == 200
        assert get_resp_header(conn, "content-type") == [served]
        assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="#{name}")]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        assert get_resp_header(conn, "content-security-policy") == ["sandbox; default-src 'none'"]
      end
    end
  end

  describe "job log" do
    test "a job's input is written once; later changes are patches that replay to the same state" do
      path = Application.fetch_env!(:omnigate_control, :jobs_path)
      marker = "input-marker-#{System.unique_integer([:positive])}"
      Provider.put(:polls_needed, 4)

      {:ok, job} = Jobs.create(key(), %{"model" => "img", "input" => %{"prompt" => marker}, "metadata" => %{"n" => 1}})
      # Wait for the last change of a finished job: its ledger entry.
      finished = await(job["id"], &(&1["ledgered"] == true))
      assert finished["status"] == "succeeded"

      lines = path |> File.read!() |> String.split("\n", trim: true) |> Enum.filter(&String.contains?(&1, job["id"]))
      assert length(lines) >= 4
      # The input appears in the creation line only.
      assert lines |> Enum.filter(&String.contains?(&1, marker)) |> length() == 1
      assert Enum.all?(tl(lines), &(JSON.decode!(&1) |> Map.has_key?("_patch")))

      open_before = Store.open_count([finished["key_sha256"]])

      # Replaying the log (snapshot line, then patches) gives back exactly the same job.
      for child <- [OmnigateControl.Webhooks, Store], do: :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, child)
      {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Store)
      {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, OmnigateControl.Webhooks)

      assert Store.get(job["id"]) == finished
      assert Store.open_count([finished["key_sha256"]]) == open_before

      # Boot compacted the log back to one full line per job.
      [line] = path |> File.read!() |> String.split("\n", trim: true) |> Enum.filter(&String.contains?(&1, job["id"]))
      assert JSON.decode!(line) == finished
    end
  end

  describe "retention defaults" do
    test "ledger ids are kept for a finite time unless told otherwise" do
      assert ConfigStore.normalize(%{}).retention.ledger_ids_days == 14
      assert ConfigStore.normalize(%{"retention" => %{"jobs_days" => 30}}).retention.ledger_ids_days == 14
      # An explicit 0 still means "keep forever".
      assert ConfigStore.normalize(%{"retention" => %{"ledger_ids_days" => 0}}).retention.ledger_ids_days == 0
      assert ConfigStore.normalize(%{"retention" => %{"ledger_ids_days" => 3}}).retention.ledger_ids_days == 3
    end
  end

  describe "ledger snapshot" do
    test "a file with a valid checksum but the wrong contents is ignored" do
      dir = Path.join(System.tmp_dir!(), "omnigate-w4-snap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "ledger.jsonl")
      File.write!(path, "")

      good = %{version: 1, covered: {1, 0}, totals: [{"k", %{}}], seen: [{"id", 5}], recent: [%{"id" => "x"}], taken_ms: 0}
      Files.write_snapshot(path, good)
      assert {:ok, %{seen: [{"id", 5}]}, :current} = Files.load_snapshot(path)

      for bad <- [
            %{good | totals: [:not_a_row]},
            %{good | totals: [{"only-a-key"}]},
            %{good | seen: [{"id", "not-a-time"}]},
            %{good | seen: ["id"]},
            %{good | recent: [:x]},
            %{good | recent: "nope"},
            %{good | covered: {-1, 0}}
          ] do
        File.rm(Files.prev_path(path))
        Files.write_snapshot(path, bad)
        File.rm(Files.prev_path(path))
        log = ExUnit.CaptureLog.capture_log(fn -> assert :none = Files.load_snapshot(path) end)
        assert log =~ "unexpected contents"
      end

      # Bytes that are not a term at all, behind a correct checksum.
      junk = <<131, 255, 255, 255>>
      File.write!(Files.snapshot_path(path), ["OMNIGATE-LEDGER-SNAPSHOT-1\n", :crypto.hash(:sha256, junk), junk])
      log = ExUnit.CaptureLog.capture_log(fn -> assert :none = Files.load_snapshot(path) end)
      assert log =~ "undecodable contents"
    end
  end

  describe "recent requests" do
    test "are still listed after the ledger restarts" do
      id = "w4-recent-#{System.unique_integer([:positive])}"

      event = %{
        "id" => id,
        "key_sha256" => OmnigateControl.sha256_hex(id),
        "route_model" => "m",
        "upstream" => "u",
        "target_model" => "t",
        "status" => 200,
        "stream" => false,
        "input_tokens" => 1,
        "output_tokens" => 1,
        "latency_ms" => 1,
        "attempts" => []
      }

      {:ok, %{accepted: 1}} = OmnigateControl.Ledger.record_batch([event])
      assert hd(OmnigateControl.Ledger.recent())["id"] == id

      :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, OmnigateControl.Ledger)
      {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, OmnigateControl.Ledger)

      assert hd(OmnigateControl.Ledger.recent())["id"] == id
      # Which is what the dashboard's "Recent requests" is built from.
      assert OmnigateControl.Admin.overview().requests != []
    end
  end
end
