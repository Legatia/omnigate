defmodule OmnigateControl.Wave2Test do
  # Swaps the live config, records into the shared ledger and restarts it, so
  # it must not run alongside other tests.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias OmnigateControl.{Admin, Audit, ConfigStore, Keys, Ledger, Rejections, Retention, Router, SigV4, Storage}
  alias OmnigateControl.Jobs.Store
  alias OmnigateControl.Storage.S3

  @admin "test-admin-token-0123456789"
  @internal "test-internal-token"
  @day_ms 86_400_000

  # A stand-in bucket: remembers every request it gets and checks DELETE
  # signatures by recomputing them from what actually arrived on the wire.
  defmodule Bucket do
    import Plug.Conn

    @creds %{access_key: "AKTEST", secret_key: "bucket-secret", region: "auto", service: "s3"}
    def creds, do: @creds

    def init(opts), do: opts

    def call(conn, _opts) do
      headers = for name <- ["host", "x-amz-content-sha256", "x-amz-date"], do: {name, conn |> get_req_header(name) |> List.first() || ""}
      [auth] = get_req_header(conn, "authorization")
      [_, sent] = Regex.run(~r/Signature=([0-9a-f]{64})$/, auth)
      [amz_date] = get_req_header(conn, "x-amz-date")

      expected =
        OmnigateControl.SigV4.signature(
          conn.method,
          conn.request_path,
          conn.query_string,
          headers,
          List.keyfind(headers, "x-amz-content-sha256", 0) |> elem(1),
          amz_date,
          @creds
        )

      Agent.update(__MODULE__, &[%{method: conn.method, path: conn.request_path, signed: sent == expected and auth =~ "Credential=AKTEST/"} | &1])

      cond do
        sent != expected -> send_resp(conn, 403, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
        conn.request_path =~ "refuse-me" -> send_resp(conn, 500, "<Error><Code>InternalError</Code></Error>")
        conn.method == "DELETE" -> send_resp(conn, 204, "")
        true -> send_resp(conn, 200, "")
      end
    end

    def requests, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  setup do
    original = :persistent_term.get({ConfigStore, :config})
    previous_token = System.get_env("OMNIGATE_INTERNAL_TOKEN")
    System.put_env("OMNIGATE_INTERNAL_TOKEN", @internal)
    Rejections.reset()

    on_exit(fn ->
      for k <- Keys.managed(), do: Keys.delete(k.name)
      :persistent_term.put({ConfigStore, :config}, original)
      if previous_token, do: System.put_env("OMNIGATE_INTERNAL_TOKEN", previous_token), else: System.delete_env("OMNIGATE_INTERNAL_TOKEN")
    end)

    {:ok, original: original}
  end

  defp put_config(config), do: :persistent_term.put({ConfigStore, :config}, config)
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp hash(name), do: OmnigateControl.sha256_hex(name)

  defp file_key(name, extra \\ %{}) do
    Map.merge(
      %{
        name: name,
        key_sha256: hash(name),
        budget_usd: nil,
        budget_period: "total",
        rpm: 0,
        models: nil,
        webhook_secret: nil,
        disabled: false,
        source: :file,
        created_at: nil,
        old_hashes: []
      },
      extra
    )
  end

  defp request(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = Router.call(conn, Router.init([]))

    json =
      case JSON.decode(conn.resp_body || "") do
        {:ok, v} -> v
        _ -> nil
      end

    {conn.status, json, conn}
  end

  defp admin, do: [{"authorization", "Bearer " <> @admin}]
  defp internal, do: [{"x-omnigate-internal", @internal}]

  defp event(key, extra) do
    Map.merge(
      %{
        "id" => unique("ev"),
        "key_sha256" => hash(key),
        "route_model" => "priced",
        "upstream" => "u",
        "target_model" => "real",
        "status" => 200,
        "input_tokens" => 0,
        "output_tokens" => 0
      },
      extra
    )
  end

  defp ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  # ---------------------------------------------------------------- cost

  describe "cost of prompt-cache tokens" do
    setup %{original: original} do
      routes =
        ConfigStore.normalize(%{
          "upstreams" => [%{"name" => "u", "kind" => "openai", "base_url" => "http://x", "api_key_env" => "K"}],
          "routes" => [
            %{
              "model" => "priced",
              "targets" => [
                %{
                  "upstream" => "u",
                  "model" => "real",
                  "price_in_per_mtok" => 1.0,
                  "price_cached_in_per_mtok" => 0.1,
                  "price_cache_write_per_mtok" => 1.25,
                  "price_out_per_mtok" => 5.0
                }
              ]
            },
            %{"model" => "plain", "targets" => [%{"upstream" => "u", "model" => "real", "price_in_per_mtok" => 2.0, "price_out_per_mtok" => 4.0}]}
          ]
        }).routes

      put_config(%{original | routes: routes})
      :ok
    end

    test "each kind of token is billed at its own price" do
      key = unique("cost")

      assert {:ok, %{accepted: 1}} =
               Ledger.record_batch([
                 event(key, %{
                   "input_tokens" => 1_000_000,
                   "cached_input_tokens" => 2_000_000,
                   "cache_write_input_tokens" => 400_000,
                   "output_tokens" => 100_000
                 })
               ])

      totals = Ledger.totals(hash(key))
      # 1.0 uncached + 2 x 0.1 cached + 0.4 x 1.25 written + 0.1 x 5.0 out
      assert_in_delta totals.cost_usd, 2.2, 1.0e-9
      assert %{input_tokens: 1_000_000, cached_input_tokens: 2_000_000, cache_write_input_tokens: 400_000, output_tokens: 100_000} = totals
    end

    test "without cache prices, cache tokens cost the input price, and an old-shape event bills as before" do
      assert ConfigStore.prices("plain", "u", "real") == %{in: 2.0, cached_in: 2.0, cache_write: 2.0, out: 4.0}
      assert ConfigStore.prices("nope", "u", "real") == %{in: 0.0, cached_in: 0.0, cache_write: 0.0, out: 0.0}

      key = unique("plain")
      Ledger.record_batch([event(key, %{"route_model" => "plain", "input_tokens" => 500_000, "cached_input_tokens" => 500_000, "output_tokens" => 250_000})])
      assert_in_delta Ledger.spend(hash(key)), 3.0, 1.0e-9

      old = unique("old")
      Ledger.record_batch([event(old, %{"route_model" => "plain", "input_tokens" => 1_000_000, "output_tokens" => 250_000})])
      assert_in_delta Ledger.spend(hash(old)), 3.0, 1.0e-9
      assert Ledger.totals(hash(old)).cached_input_tokens == 0
    end

    test "a response served from the data plane's cache counts as a request and costs nothing" do
      key = unique("cached")
      Ledger.record_batch([event(key, %{"cached" => true, "input_tokens" => 1_000_000, "output_tokens" => 1_000_000})])
      assert %{requests: 1, cached_responses: 1, cost_usd: +0.0} = Ledger.totals(hash(key))
    end

    test "negative or non-integer cache token counts make an event invalid" do
      assert {:ok, %{accepted: 0, invalid: 2}} =
               Ledger.record_batch([event("x", %{"cached_input_tokens" => -1}), event("x", %{"cache_write_input_tokens" => "many"})])
    end

    test "bad prices are refused when the config loads" do
      route = fn target -> %{"routes" => [%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "a"}, target)]}]} end

      assert_raise ArgumentError, ~r/a price must be a number of dollars per 1M tokens/, fn ->
        ConfigStore.normalize(route.(%{"price_cached_in_per_mtok" => -1}))
      end

      assert_raise ArgumentError, ~r/a price must be a number/, fn -> ConfigStore.normalize(route.(%{"price_cache_write_per_mtok" => "cheap"})) end
    end

    test "the key view, overview and metrics carry the cache token counts", %{original: original} do
      name = unique("view")
      put_config(%{:persistent_term.get({ConfigStore, :config}) | keys: [file_key(name)]})
      Ledger.record_batch([event(name, %{"input_tokens" => 10, "cached_input_tokens" => 70, "cache_write_input_tokens" => 5, "output_tokens" => 3})])

      assert {200, %{"keys" => [row]}, _} = request(:get, "/admin/usage", nil, admin())
      assert %{"cached_input_tokens" => 70, "cache_write_input_tokens" => 5, "input_tokens" => 10} = row

      {200, overview, _} = request(:get, "/admin/overview", nil, admin())
      assert %{"cached_input_tokens" => 70, "cache_write_input_tokens" => 5, "cached" => false} = Enum.find(overview["requests"], &(&1["key"] == name))
      assert overview["totals"]["cached_input_tokens"] >= 70

      {200, _, conn} = request(:get, "/metrics", nil, admin())
      assert conn.resp_body =~ ~s(omnigate_key_cached_input_tokens_total{key="#{name}"} 70\n)
      assert conn.resp_body =~ ~s(omnigate_key_cache_write_input_tokens_total{key="#{name}"} 5\n)

      {200, _, page} = request(:get, "/", nil, admin())
      assert page.resp_body =~ "+ 70 cache read</span>"
      assert page.resp_body =~ "+ 5 cache write</span>"
      _ = original
    end
  end

  # ---------------------------------------------------------------- budget periods

  describe "budget periods" do
    test "a monthly budget counts only this month, and the key unblocks when the month turns", %{original: original} do
      name = unique("monthly")
      key = file_key(name, %{budget_usd: 1.0, budget_period: "monthly"})
      put_config(%{original | keys: [key]})

      now = ~U[2026-11-10 12:00:00Z]
      media = fn id, at, cost -> Ledger.record_media(%{"id" => id, "key_sha256" => hash(name), "status" => 200, "cost_usd" => cost, "ts_ms" => ms(at)}) end

      # A lot was spent last month: irrelevant now.
      media.(unique("oct"), ~U[2026-10-31 23:59:59Z], 50.0)
      refute Keys.over_budget?(key, now)
      assert Keys.period_spend(key, now) == 0.0

      media.(unique("nov"), ~U[2026-11-01 00:00:00Z], 0.4)
      refute Keys.over_budget?(key, now)
      media.(unique("nov"), ~U[2026-11-09 08:00:00Z], 0.6)
      assert_in_delta Keys.period_spend(key, now), 1.0, 1.0e-9
      assert Keys.over_budget?(key, now)

      # December: a new period, the key works again without anyone touching it.
      refute Keys.over_budget?(key, ~U[2026-12-01 00:00:00Z])
      assert Keys.period_resets_at(key, now) == "2026-12-01T00:00:00Z"
      assert Keys.period_resets_at(key, ~U[2026-12-31 23:00:00Z]) == "2027-01-01T00:00:00Z"
      # The lifetime total is still there.
      assert_in_delta Ledger.spend(hash(name)), 51.0, 1.0e-9
    end

    test "a daily budget counts only today, and a total budget counts everything", %{original: original} do
      name = unique("daily")
      daily = file_key(name, %{budget_usd: 1.0, budget_period: "daily"})
      total = %{daily | budget_period: "total"}
      put_config(%{original | keys: [daily]})

      Ledger.record_media(%{"id" => unique("d"), "key_sha256" => hash(name), "status" => 200, "cost_usd" => 2.0, "ts_ms" => ms(~U[2026-11-09 23:59:00Z])})

      refute Keys.over_budget?(daily, ~U[2026-11-10 00:00:01Z])
      assert Keys.over_budget?(daily, ~U[2026-11-09 23:59:30Z])
      assert Keys.period_resets_at(daily, ~U[2026-11-10 00:00:01Z]) == "2026-11-11T00:00:00Z"
      assert Keys.over_budget?(total, ~U[2026-11-10 00:00:01Z])
      assert Keys.period_resets_at(total) == nil
    end

    test "period spend is rebuilt from the ledger file after a restart" do
      name = unique("replay")
      now = DateTime.utc_now()
      Ledger.record_media(%{"id" => unique("r"), "key_sha256" => hash(name), "status" => 200, "cost_usd" => 0.75, "ts_ms" => ms(now)})
      assert_in_delta Ledger.period_spend(hash(name), "monthly", now), 0.75, 1.0e-9

      capture_log(fn ->
        :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Ledger)
        {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Ledger)
      end)

      assert_in_delta Ledger.period_spend(hash(name), "monthly", now), 0.75, 1.0e-9
      assert_in_delta Ledger.period_spend(hash(name), "daily", now), 0.75, 1.0e-9
      assert_in_delta Ledger.spend(hash(name)), 0.75, 1.0e-9
    end

    test "rows of periods long past are dropped from memory; the current ones stay" do
      name = unique("prune")
      now = ~U[2026-11-10 12:00:00Z]

      for at <- [~U[2026-08-15 00:00:00Z], ~U[2026-11-10 09:00:00Z]] do
        Ledger.record_media(%{"id" => unique("p"), "key_sha256" => hash(name), "status" => 200, "cost_usd" => 1.0, "ts_ms" => ms(at)})
      end

      assert Ledger.period_spend(hash(name), "monthly", ~U[2026-08-20 00:00:00Z]) == 1.0
      assert :ok = Ledger.prune_period_rows(now)
      assert Ledger.period_spend(hash(name), "monthly", ~U[2026-08-20 00:00:00Z]) == 0.0
      assert Ledger.period_spend(hash(name), "daily", ~U[2026-08-15 10:00:00Z]) == 0.0
      assert Ledger.period_spend(hash(name), "monthly", now) == 1.0
      assert Ledger.period_spend(hash(name), "daily", now) == 1.0
      # Totals never change.
      assert Ledger.spend(hash(name)) == 2.0
    end

    test "the config file and the admin API both take and validate budget_period" do
      assert [%{budget_period: "total"}, %{budget_period: "daily"}] =
               ConfigStore.normalize(%{"keys" => [%{"name" => "a", "key" => "x"}, %{"name" => "b", "key" => "y", "budget_period" => "daily"}]}).keys

      assert_raise ArgumentError, ~r/key "k": "budget_period" must be one of total, monthly, daily, got "weekly"/, fn ->
        ConfigStore.normalize(%{"keys" => [%{"name" => "k", "key" => "x", "budget_period" => "weekly"}]})
      end

      name = unique("api")
      assert {201, created, _} = request(:post, "/admin/keys", %{"name" => name, "budget_usd" => 5, "budget_period" => "monthly"}, admin())
      assert %{"budget_period" => "monthly", "period_spend_usd" => +0.0, "period_resets_at" => resets} = created
      assert {:ok, at, 0} = DateTime.from_iso8601(resets)
      assert at.day == 1 and DateTime.compare(at, DateTime.utc_now()) == :gt

      assert {400, %{"error" => %{"message" => message}}, _} = request(:patch, "/admin/keys/#{name}", %{"budget_period" => "weekly"}, admin())
      assert message =~ "budget_period"
      assert {200, %{"budget_period" => "daily"}, _} = request(:patch, "/admin/keys/#{name}", %{"budget_period" => "daily"}, admin())
      assert %{budget_period: "daily"} = Keys.find(name)
    end

    test "the snapshot blocks a key by its period spend, and metrics show the period figure", %{original: original} do
      name = unique("snap")
      put_config(%{original | keys: [file_key(name, %{budget_usd: 1.0, budget_period: "daily"})]})

      # Yesterday's overspend does not block today.
      Ledger.record_media(%{
        "id" => unique("y"),
        "key_sha256" => hash(name),
        "status" => 200,
        "cost_usd" => 9.0,
        "ts_ms" => System.os_time(:millisecond) - 2 * @day_ms
      })

      assert {200, %{"keys" => [%{"blocked" => false}]}, _} = request(:get, "/internal/config", nil, internal())

      Ledger.record_media(%{"id" => unique("t"), "key_sha256" => hash(name), "status" => 200, "cost_usd" => 1.5})
      assert {200, %{"keys" => [%{"blocked" => true}]}, _} = request(:get, "/internal/config", nil, internal())

      {200, _, conn} = request(:get, "/metrics", nil, admin())
      assert conn.resp_body =~ ~s(omnigate_key_period_cost_usd{key="#{name}"} 1.5\n)
      assert conn.resp_body =~ ~s(omnigate_key_cost_usd_total{key="#{name}"} 10.5\n)
      assert conn.resp_body =~ ~s(omnigate_key_blocked{key="#{name}"} 1\n)

      {200, _, page} = request(:get, "/", nil, admin())
      assert page.resp_body =~ "of $1.0000 today"
      assert page.resp_body =~ "$10.5000 in total"
    end
  end

  # ---------------------------------------------------------------- refused requests

  describe "refused-request counters" do
    test "data planes report them; malformed entries are ignored" do
      body = %{
        "counters" => [
          %{"key" => "my-app", "reason" => "rate_limit_exceeded", "count" => 12},
          %{"key" => "my-app", "reason" => "rate_limit_exceeded", "count" => 3},
          %{"key" => "-", "reason" => "invalid_api_key", "count" => 7},
          %{"key" => "my-app", "reason" => "Not A Reason!", "count" => 1},
          %{"key" => "my-app", "reason" => "model_not_allowed", "count" => 0},
          %{"key" => "my-app", "reason" => "model_not_allowed", "count" => -4},
          %{"key" => String.duplicate("k", 65), "reason" => "x", "count" => 1},
          %{"reason" => "no_key_field", "count" => 1},
          "nonsense"
        ]
      }

      assert {401, _, _} = request(:post, "/internal/counters", body)
      assert {200, %{"accepted" => 3}, _} = request(:post, "/internal/counters", body, internal())
      assert {400, _, _} = request(:post, "/internal/counters", %{"counters" => "many"}, internal())

      assert [%{key: "my-app", reason: "rate_limit_exceeded", count: 15}, %{key: "-", reason: "invalid_api_key", count: 7}] = Rejections.all()

      {200, _, conn} = request(:get, "/metrics", nil, admin())
      assert conn.resp_body =~ "# TYPE omnigate_rejected_requests_total counter\n"
      assert conn.resp_body =~ ~s(omnigate_rejected_requests_total{key="my-app",reason="rate_limit_exceeded"} 15\n)
      assert conn.resp_body =~ ~s(omnigate_rejected_requests_total{key="-",reason="invalid_api_key"} 7\n)

      {200, overview, _} = request(:get, "/admin/overview", nil, admin())
      assert [%{"key" => "my-app", "reason" => "rate_limit_exceeded", "count" => 15} | _] = overview["rejected"]

      {200, _, page} = request(:get, "/", nil, admin())
      assert page.resp_body =~ "Refused requests"
      assert page.resp_body =~ "(no valid key)"
    end

    test "the number of series is capped; the overflow is still counted" do
      counters = for i <- 1..2_050, do: %{"key" => "k#{i}", "reason" => "invalid_api_key", "count" => 1}
      assert Rejections.record(counters) == 2_050

      all = Rejections.all()
      # 2,000 series of their own, plus the one everything else is folded into.
      assert length(all) == 2_001
      assert %{count: 50} = Enum.find(all, &(&1.key == "-" and &1.reason == "other"))
      assert Enum.sum(Enum.map(all, & &1.count)) == 2_050
    end
  end

  # ---------------------------------------------------------------- snapshot

  describe "the snapshot for data planes" do
    test "names the media models and each text route's cache time", %{original: original} do
      extra =
        ConfigStore.normalize(%{
          "upstreams" => [%{"name" => "u", "kind" => "openai", "base_url" => "http://x", "api_key_env" => "K"}],
          "routes" => [
            %{"model" => "cached-route", "cache_ttl_s" => 300, "targets" => [%{"upstream" => "u", "model" => "a"}]},
            %{"model" => "plain-route", "targets" => [%{"upstream" => "u", "model" => "a"}]}
          ],
          "media" => %{
            "upstreams" => [%{"name" => "r", "kind" => "replicate", "base_url" => "http://x", "api_key_env" => "K"}],
            "routes" => [
              %{"model" => "an-image", "targets" => [%{"upstream" => "r", "model" => "o/m"}]},
              %{"model" => "a-video", "targets" => [%{"upstream" => "r", "model" => "o/v"}]}
            ]
          }
        })

      put_config(%{original | routes: extra.routes, media: extra.media})
      assert {200, snapshot, _} = request(:get, "/internal/config", nil, internal())
      assert snapshot["media_models"] == ["an-image", "a-video"]
      assert [%{"model" => "cached-route", "cache_ttl_s" => 300}, %{"model" => "plain-route", "cache_ttl_s" => 0}] = snapshot["routes"]

      # A different cache time is a different snapshot version.
      put_config(%{original | routes: [%{hd(extra.routes) | cache_ttl_s: 60}], media: extra.media})
      assert {200, changed, _} = request(:get, "/internal/config", nil, internal())
      assert changed["version"] != snapshot["version"]
    end

    test "a bad cache time is refused when the config loads" do
      for bad <- [-1, 1.5, "long"] do
        assert_raise ArgumentError, ~r/route "m": "cache_ttl_s" must be a whole number of seconds/, fn ->
          ConfigStore.normalize(%{"routes" => [%{"model" => "m", "cache_ttl_s" => bad, "targets" => []}]})
        end
      end
    end
  end

  # ---------------------------------------------------------------- audit log

  describe "the audit log" do
    test "records key changes and sign-ins, and never a secret" do
      name = unique("audited")
      path = Application.fetch_env!(:omnigate_control, :audit_path)

      {201, %{"key" => raw}, _} = request(:post, "/admin/keys", %{"name" => name, "webhook_secret" => "whs-do-not-log"}, admin())
      {409, _, _} = request(:post, "/admin/keys", %{"name" => name}, admin())
      {200, _, _} = request(:patch, "/admin/keys/#{name}", %{"rpm" => 9, "webhook_secret" => "whs-also-not"}, admin())
      {200, %{"key" => rotated}, _} = request(:post, "/admin/keys/#{name}/rotate", nil, admin())
      {200, _, _} = request(:delete, "/admin/keys/#{name}", nil, admin())
      {404, _, _} = request(:delete, "/admin/keys/#{name}", nil, admin())

      login = fn password ->
        conn(:post, "/login", "password=" <> URI.encode_www_form(password))
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-forwarded-for", "198.51.100.9")
        |> Map.put(:remote_ip, {10, 9, 8, 7})
        |> Router.call(Router.init([]))
      end

      assert login.("wrong-password-attempt").status == 401
      ok = login.(@admin)
      assert ok.status == 302
      cookie = OmnigateControl.AdminAuth.cookie_name() <> "=" <> ok.resp_cookies[OmnigateControl.AdminAuth.cookie_name()].value
      csrf = OmnigateControl.AdminAuth.csrf_token(ok.resp_cookies[OmnigateControl.AdminAuth.cookie_name()].value)

      # A change made from the dashboard is recorded as a session action.
      {201, _, _} = request(:post, "/admin/keys", %{"name" => name <> "-ui"}, [{"cookie", cookie}, {"x-csrf-token", csrf}])

      out =
        conn(:post, "/logout", "_csrf=" <> csrf)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("cookie", cookie)
        |> Router.call(Router.init([]))

      assert out.status == 302

      assert {200, %{"entries" => entries}, _} = request(:get, "/admin/audit?limit=20", nil, admin())
      mine = entries |> Enum.take(10) |> Enum.reverse()

      assert [
               %{"action" => "key.create", "target" => ^name, "outcome" => "ok", "auth" => "token"},
               %{"action" => "key.create", "target" => ^name, "outcome" => "key_exists"},
               %{"action" => "key.update", "outcome" => "ok", "fields" => ["rpm", "webhook_secret"]},
               %{"action" => "key.rotate", "outcome" => "ok"},
               %{"action" => "key.delete", "outcome" => "ok"},
               %{"action" => "key.delete", "outcome" => "key_not_found"},
               %{"action" => "login", "outcome" => "denied", "auth" => "password", "address" => "10.9.8.7", "forwarded_for" => "198.51.100.9"},
               %{"action" => "login", "outcome" => "ok", "auth" => "password"},
               %{"action" => "key.create", "outcome" => "ok", "auth" => "session"},
               %{"action" => "logout", "outcome" => "ok", "auth" => "session"}
             ] = mine

      assert Enum.all?(mine, &match?({:ok, _, 0}, DateTime.from_iso8601(&1["ts"])))

      # On disk, one JSON object per line, and no secret of any kind.
      text = File.read!(path)
      assert length(String.split(text, "\n", trim: true)) >= 10
      for secret <- [raw, rotated, @admin, "whs-do-not-log", "whs-also-not", "wrong-password-attempt", cookie, csrf], do: refute(text =~ secret)

      assert {401, _, _} = request(:get, "/admin/audit")
      assert {200, %{"entries" => [_]}, _} = request(:get, "/admin/audit?limit=1", nil, admin())

      {200, overview, _} = request(:get, "/admin/overview", nil, admin())
      assert [%{"action" => "logout"} | _] = overview["audit"]
      {200, _, page} = request(:get, "/", nil, admin())
      assert page.resp_body =~ "Admin activity"
      assert page.resp_body =~ "key.rotate"
    end

    test "entries survive a restart of the log process" do
      Audit.record(conn(:post, "/x"), "key.create", "restart-probe", "ok", auth: "token")

      capture_log(fn ->
        :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Audit)
        {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Audit)
      end)

      assert [%{"target" => "restart-probe"} | _] = Audit.recent(5)
    end
  end

  # ---------------------------------------------------------------- bucket retention

  describe "retention with bucket storage" do
    setup %{original: original} do
      start_supervised!(%{id: Bucket, start: {Agent, :start_link, [fn -> [] end, [name: Bucket]]}})
      {:ok, server} = Bandit.start_link(plug: Bucket, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      System.put_env("W2_S3_ACCESS", Bucket.creds().access_key)
      System.put_env("W2_S3_SECRET", Bucket.creds().secret_key)

      storage =
        ConfigStore.normalize(%{
          "media" => %{
            "storage" => %{
              "kind" => "s3",
              "endpoint" => "http://127.0.0.1:#{port}",
              "bucket" => "b",
              "region" => "auto",
              "prefix" => "out",
              "access_key_env" => "W2_S3_ACCESS",
              "secret_key_env" => "W2_S3_SECRET"
            }
          }
        }).media.storage

      put_config(%{original | media: %{original.media | storage: storage}})

      on_exit(fn ->
        System.delete_env("W2_S3_ACCESS")
        System.delete_env("W2_S3_SECRET")
      end)

      {:ok, storage: storage}
    end

    defp job_id, do: "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    defp s3_job(id, finished_ms, outputs, extra \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "status" => "succeeded",
          "model" => "w2-retention",
          "input" => %{},
          "outputs" => outputs,
          "cost_usd" => 0.0,
          "cached" => false,
          "attempts" => [],
          "webhook" => nil,
          "key_sha256" => "w2-key",
          "created_ms" => finished_ms - 1_000,
          "finished_ms" => finished_ms,
          "ledgered" => true
        },
        extra
      )
    end

    defp out(name, key), do: %{"name" => name, "storage" => "s3", "key" => key, "content_type" => "image/png", "bytes" => 4}

    test "the DELETE request is signed with SigV4 over an empty body", %{storage: storage} do
      now = ~U[2026-11-10 12:00:00Z]
      {url, headers} = S3.delete_request(storage, "out/job_ab/out-0.png", Bucket.creds(), now)
      assert url == storage.endpoint <> "/b/out/job_ab/out-0.png"

      map = Map.new(headers)
      empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      assert map["x-amz-content-sha256"] == empty
      assert map["x-amz-date"] == "20261110T120000Z"

      host = URI.parse(storage.endpoint).authority

      signature =
        SigV4.signature(
          "DELETE",
          "/b/out/job_ab/out-0.png",
          "",
          [{"host", host}, {"x-amz-content-sha256", empty}, {"x-amz-date", "20261110T120000Z"}],
          empty,
          "20261110T120000Z",
          Bucket.creds()
        )

      assert map["authorization"] ==
               "AWS4-HMAC-SHA256 Credential=AKTEST/20261110/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=#{signature}"
    end

    test "a sweep deletes the removed jobs' own objects, and nothing else" do
      now = System.os_time(:millisecond)
      old_id = job_id()
      shared_id = job_id()

      # An old job with two objects of its own, one record that points somewhere it should not, and one local file.
      {:ok, _} =
        Store.create(
          s3_job(old_id, now - 40 * @day_ms, [
            out("out-0.png", "out/#{old_id}/out-0.png"),
            out("out-1.png", "out/#{old_id}/out-1.png"),
            out("evil.png", "someone-elses/backups/db.dump"),
            %{"name" => "local.png", "storage" => "local"}
          ])
        )

      # Another old job whose object a recent cache-hit job still uses.
      {:ok, _} = Store.create(s3_job(shared_id, now - 40 * @day_ms, [out("out-0.png", "out/#{shared_id}/out-0.png")]))
      {:ok, recent} = Store.create(s3_job(job_id(), now - 1 * @day_ms, [out("out-0.png", "out/#{shared_id}/out-0.png")], %{"cached" => true}))

      result = Retention.sweep(%{jobs_days: 30, ledger_ids_days: 0, delete_bucket_objects: true}, now)
      assert result.jobs >= 2
      assert result.bucket_objects == 2

      deletes = for %{method: "DELETE"} = r <- Bucket.requests(), do: r
      assert Enum.sort(Enum.map(deletes, & &1.path)) == ["/b/out/#{old_id}/out-0.png", "/b/out/#{old_id}/out-1.png"]
      assert Enum.all?(deletes, & &1.signed)

      assert Store.get(old_id) == nil
      assert Store.get(shared_id) == nil
      assert Store.get(recent["id"])
    end

    test "it can be switched off, and a failed delete is logged and does not stop the sweep" do
      now = System.os_time(:millisecond)
      kept_id = job_id()
      {:ok, _} = Store.create(s3_job(kept_id, now - 40 * @day_ms, [out("out-0.png", "out/#{kept_id}/out-0.png")]))

      result = Retention.sweep(%{jobs_days: 30, ledger_ids_days: 0, delete_bucket_objects: false}, now)
      assert result.jobs >= 1 and result.bucket_objects == 0
      assert Bucket.requests() == []

      bad_id = job_id()
      good_id = job_id()
      {:ok, _} = Store.create(s3_job(bad_id, now - 40 * @day_ms, [out("refuse-me.png", "out/#{bad_id}/refuse-me.png")]))
      {:ok, _} = Store.create(s3_job(good_id, now - 40 * @day_ms, [out("out-0.png", "out/#{good_id}/out-0.png")]))

      log = capture_log(fn -> assert %{bucket_objects: 1} = Retention.sweep(%{jobs_days: 30, ledger_ids_days: 0}, now) end)
      assert log =~ "could not delete bucket object out/#{bad_id}/refuse-me.png"
      assert log =~ "s3 delete returned 500"
      assert Store.get(bad_id) == nil
    end

    test "nothing is deleted from a bucket when storage is local", %{original: original} do
      put_config(%{original | media: %{original.media | storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600}}})
      id = job_id()
      assert Storage.delete_remote([s3_job(id, 0, [out("out-0.png", "out/#{id}/out-0.png")])], []) == 0
      assert Bucket.requests() == []
    end

    test "retention.delete_bucket_objects is on by default and must be a boolean" do
      assert ConfigStore.normalize(%{"retention" => %{"jobs_days" => 30}}).retention == %{
               jobs_days: 30,
               ledger_ids_days: 3,
               ledger_days: 0,
               delete_bucket_objects: true,
               private_outputs_hours: 24
             }

      assert ConfigStore.normalize(%{"retention" => %{"delete_bucket_objects" => false}}).retention.delete_bucket_objects == false

      assert_raise ArgumentError, ~r/retention.delete_bucket_objects must be true or false/, fn ->
        ConfigStore.normalize(%{"retention" => %{"delete_bucket_objects" => "no"}})
      end
    end
  end

  # ---------------------------------------------------------------- startup

  describe "the internal token" do
    test "an empty variable counts as unset, and the application environment is only a fallback" do
      System.put_env("OMNIGATE_INTERNAL_TOKEN", "from-env")
      assert OmnigateControl.internal_token() == "from-env"

      System.put_env("OMNIGATE_INTERNAL_TOKEN", "")
      assert OmnigateControl.internal_token() == Application.get_env(:omnigate_control, :internal_token)
      System.delete_env("OMNIGATE_INTERNAL_TOKEN")
      assert OmnigateControl.internal_token() == Application.get_env(:omnigate_control, :internal_token)
    end

    test "the control plane refuses to start without one" do
      fallback = Application.get_env(:omnigate_control, :internal_token)
      System.put_env("OMNIGATE_INTERNAL_TOKEN", "")
      Application.delete_env(:omnigate_control, :internal_token)

      try do
        log =
          capture_log(fn ->
            assert {:error, message} = OmnigateControl.Application.start(:normal, [])
            assert message =~ "OMNIGATE_INTERNAL_TOKEN is not set"
          end)

        assert log =~ "OMNIGATE_INTERNAL_TOKEN is not set"
        # And with none, every internal call is refused whatever it presents.
        assert {401, _, _} = request(:get, "/internal/config", nil, [{"x-omnigate-internal", ""}])
      after
        Application.put_env(:omnigate_control, :internal_token, fallback)
      end
    end
  end

  test "the overview document lists what the dashboard needs" do
    {200, overview, _} = request(:get, "/admin/overview", nil, admin())
    assert Enum.sort(Map.keys(overview)) == ~w(audit config generated_at jobs keys redactions rejected requests today totals)
    assert %{"delete_bucket_objects" => _, "jobs_days" => _, "ledger_ids_days" => _} = overview["config"]["retention"]
    assert is_list(Admin.overview().audit)
  end
end
