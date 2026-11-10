defmodule OmnigateControl.AdminKeysTest do
  # Changes the shared key store and live config, so not alongside other tests.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias OmnigateControl.{AdminAuth, ConfigStore, Http, Keys, Ledger, Router, Webhooks}

  @admin "test-admin-token-0123456789"
  @internal "test-internal-token"

  setup do
    original = :persistent_term.get({ConfigStore, :config})
    previous_token = System.get_env("OMNIGATE_INTERNAL_TOKEN")
    System.put_env("OMNIGATE_INTERNAL_TOKEN", @internal)

    on_exit(fn ->
      for k <- Keys.managed(), do: Keys.delete(k.name)
      :persistent_term.put({ConfigStore, :config}, original)
      Application.delete_env(:omnigate_control, :webhook_resolver)
      if previous_token, do: System.put_env("OMNIGATE_INTERNAL_TOKEN", previous_token), else: System.delete_env("OMNIGATE_INTERNAL_TOKEN")
    end)

    :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp request(method, path, body, headers) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = Router.call(conn, Router.init([]))

    json =
      case JSON.decode(conn.resp_body || "") do
        {:ok, value} -> value
        _ -> nil
      end

    {conn.status, json, conn}
  end

  defp admin(method, path, body \\ nil), do: request(method, path, body, [{"authorization", "Bearer " <> @admin}])

  defp snapshot do
    {200, body, _} = request(:get, "/internal/config", nil, [{"x-omnigate-internal", @internal}])
    body
  end

  defp snapshot_key(name), do: Enum.find(snapshot()["keys"], &(&1["name"] == name))

  describe "managed keys over the admin API" do
    test "create, list, change, rotate, delete" do
      name = unique("app")
      version_before = snapshot()["version"]

      assert {201, created, _} = admin(:post, "/admin/keys", %{"name" => name, "budget_usd" => 5, "rpm" => 60, "models" => ["demo-chat"]})
      raw = created["key"]
      assert "og-" <> secret = raw
      assert byte_size(secret) >= 32 and secret =~ ~r/^[A-Za-z0-9_-]+$/
      assert %{"name" => ^name, "source" => "managed", "budget_usd" => 5.0, "rpm" => 60, "models" => ["demo-chat"], "state" => "active"} = created
      assert created["created_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/

      # Data planes learn about it from the next snapshot, by hash only.
      hash = OmnigateControl.sha256_hex(raw)
      assert %{"key_sha256" => ^hash, "blocked" => false, "rpm" => 60, "models" => ["demo-chat"]} = snapshot_key(name)
      assert snapshot()["version"] != version_before

      # Listed with usage, never with the key or its hash.
      assert {200, %{"keys" => keys}, conn} = admin(:get, "/admin/keys")
      listed = Enum.find(keys, &(&1["name"] == name))
      assert %{"requests" => 0, "cost_usd" => +0.0, "disabled" => false, "blocked" => false} = listed
      refute Map.has_key?(listed, "key") or Map.has_key?(listed, "key_sha256")
      refute conn.resp_body =~ secret
      refute conn.resp_body =~ hash
      assert Enum.any?(keys, &(&1["source"] == "file"))

      # Change it.
      assert {200, %{"budget_usd" => 0.5, "rpm" => 0, "models" => nil}, _} =
               admin(:patch, "/admin/keys/#{name}", %{"budget_usd" => 0.5, "rpm" => 0, "models" => nil})

      assert %{"rpm" => 0, "models" => nil} = snapshot_key(name)

      # Spend past the budget: blocked, like a file key.
      {:ok, _} =
        Ledger.record_media(%{"id" => unique("evt"), "key_sha256" => hash, "status" => 200, "cost_usd" => 0.75, "route_model" => "x"})

      assert %{"blocked" => true} = snapshot_key(name)
      assert {200, %{"keys" => keys}, _} = admin(:get, "/admin/keys")
      assert %{"state" => "blocked", "cost_usd" => 0.75, "requests" => 1} = Enum.find(keys, &(&1["name"] == name))

      # Rotate: a new secret, the old one is gone, the spend stays.
      assert {200, %{"key" => "og-" <> _ = rotated, "cost_usd" => 0.75, "state" => "blocked"}, _} = admin(:post, "/admin/keys/#{name}/rotate")
      assert rotated != raw
      new_hash = OmnigateControl.sha256_hex(rotated)
      assert %{"key_sha256" => ^new_hash, "blocked" => true} = snapshot_key(name)
      refute Enum.any?(snapshot()["keys"], &(&1["key_sha256"] == hash))

      # Disable: data planes no longer hear of it at all; enable brings it back.
      assert {200, %{"disabled" => true, "state" => "disabled"}, _} = admin(:patch, "/admin/keys/#{name}", %{"disabled" => true})
      assert snapshot_key(name) == nil
      assert {401, _, _} = request(:get, "/internal/v1/jobs", nil, [{"x-omnigate-internal", @internal}, {"x-omnigate-key-sha256", new_hash}])
      assert {200, %{"disabled" => false}, _} = admin(:patch, "/admin/keys/#{name}", %{"disabled" => false})
      assert snapshot_key(name) != nil

      # Delete.
      assert {200, %{"deleted" => ^name}, _} = admin(:delete, "/admin/keys/#{name}")
      assert snapshot_key(name) == nil
      assert {404, %{"error" => %{"type" => "key_not_found"}}, _} = admin(:delete, "/admin/keys/#{name}")
      # The ledger keeps what the key spent.
      assert Ledger.totals(hash).cost_usd == 0.75
    end

    test "bad input is refused with a reason, and names cannot clash" do
      for {body, hint} <- [
            {%{}, "name"},
            {%{"name" => "has space"}, "name"},
            {%{"name" => String.duplicate("a", 65)}, "name"},
            {%{"name" => unique("k"), "budget_usd" => -1}, "budget_usd"},
            {%{"name" => unique("k"), "budget_usd" => "ten"}, "budget_usd"},
            {%{"name" => unique("k"), "rpm" => 1.5}, "rpm"},
            {%{"name" => unique("k"), "models" => "demo-chat"}, "models"},
            {%{"name" => unique("k"), "models" => [1]}, "models"},
            {%{"name" => unique("k"), "disabled" => "yes"}, "disabled"}
          ] do
        assert {400, %{"error" => %{"type" => "invalid_request", "message" => message}}, _} = admin(:post, "/admin/keys", body)
        assert message =~ hint
      end

      name = unique("dup")
      assert {201, _, _} = admin(:post, "/admin/keys", %{"name" => name})
      assert {409, %{"error" => %{"type" => "key_exists"}}, _} = admin(:post, "/admin/keys", %{"name" => name})

      [file_key | _] = ConfigStore.file_keys()
      assert {409, %{"error" => %{"type" => "key_exists"}}, _} = admin(:post, "/admin/keys", %{"name" => file_key.name})
      assert {400, _, _} = admin(:patch, "/admin/keys/#{name}", %{"rpm" => -3})
    end

    test "keys from the config file are read-only here" do
      [file_key | _] = ConfigStore.file_keys()

      for {method, path, body} <- [
            {:patch, "/admin/keys/#{file_key.name}", %{"rpm" => 1}},
            {:post, "/admin/keys/#{file_key.name}/rotate", nil},
            {:delete, "/admin/keys/#{file_key.name}", nil}
          ] do
        assert {409, %{"error" => %{"type" => "read_only_key", "message" => message}}, _} = admin(method, path, body)
        assert message =~ "config file"
      end

      assert Enum.any?(ConfigStore.file_keys(), &(&1.name == file_key.name))
    end

    test "the store survives a restart and never holds or logs the key itself" do
      name = unique("persist")

      {log, raw} =
        with_log(fn ->
          {201, %{"key" => raw}, _} = admin(:post, "/admin/keys", %{"name" => name, "rpm" => 7})
          raw
        end)
        |> then(fn {raw, log} -> {log, raw} end)

      refute log =~ raw

      path = Application.get_env(:omnigate_control, :keys_path)
      on_disk = File.read!(path)
      refute on_disk =~ raw
      assert on_disk =~ OmnigateControl.sha256_hex(raw)
      refute File.exists?(path <> ".tmp")

      # Kill the store; its supervisor starts a new one, which reads the file.
      pid = Process.whereis(Keys)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      wait_until(fn -> is_pid(Process.whereis(Keys)) and Process.whereis(Keys) != pid end)

      assert %{rpm: 7, source: :managed} = Enum.find(Keys.managed(), &(&1.name == name))
      assert snapshot_key(name)["key_sha256"] == OmnigateControl.sha256_hex(raw)
    end
  end

  describe "sessions and CSRF" do
    setup do
      session = AdminAuth.issue_session()
      {:ok, cookie: {"cookie", AdminAuth.cookie_name() <> "=" <> session}, csrf: AdminAuth.csrf_token(session)}
    end

    test "a cookie-authenticated change needs the session's CSRF token", %{cookie: cookie, csrf: csrf} do
      name = unique("csrf")

      assert {403, %{"error" => %{"type" => "csrf_failed"}}, _} = request(:post, "/admin/keys", %{"name" => name}, [cookie])
      assert {403, _, _} = request(:post, "/admin/keys", %{"name" => name}, [cookie, {"x-csrf-token", "wrong"}])
      # A token from another session is no good either.
      other = AdminAuth.csrf_token(AdminAuth.issue_session())
      assert {403, _, _} = request(:post, "/admin/keys", %{"name" => name}, [cookie, {"x-csrf-token", other}])
      assert Keys.find(name) == nil

      assert {201, _, _} = request(:post, "/admin/keys", %{"name" => name}, [cookie, {"x-csrf-token", csrf}])
      assert {403, _, _} = request(:delete, "/admin/keys/#{name}", nil, [cookie])
      assert {200, _, _} = request(:delete, "/admin/keys/#{name}", nil, [cookie, {"x-csrf-token", csrf}])

      # Reading needs no token.
      assert {200, _, _} = request(:get, "/admin/keys", nil, [cookie])
    end

    test "the bearer token needs no CSRF token" do
      name = unique("bearer")
      assert {201, _, _} = admin(:post, "/admin/keys", %{"name" => name})
      assert {200, _, _} = admin(:delete, "/admin/keys/#{name}")
    end

    test "logout from a session needs the token too", %{cookie: {_, cookie_value}, csrf: csrf} do
      logout = fn form ->
        conn(:post, "/logout", form)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("cookie", cookie_value)
        |> Router.call(Router.init([]))
      end

      assert logout.("").status == 403
      conn = logout.("_csrf=" <> csrf)
      assert conn.status == 302
      assert conn.resp_cookies[AdminAuth.cookie_name()].max_age == 0
    end
  end

  describe "the dashboard" do
    setup do
      session = AdminAuth.issue_session()
      {:ok, cookie: {"cookie", AdminAuth.cookie_name() <> "=" <> session}, csrf: AdminAuth.csrf_token(session)}
    end

    test "renders server-side for a session, under a nonce-only content policy", %{cookie: cookie, csrf: csrf} do
      {201, _, _} = admin(:post, "/admin/keys", %{"name" => "dash-managed", "budget_usd" => 2})
      {200, _, conn} = request(:get, "/", nil, [cookie])

      [policy] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/script-src 'nonce-([A-Za-z0-9_-]+)'/, policy)
      assert policy =~ "default-src 'none'"
      refute policy =~ "unsafe-inline"
      assert conn.resp_body =~ ~s(<script nonce="#{nonce}">)
      assert conn.resp_body =~ ~s(<style nonce="#{nonce}">)
      # Nothing is fetched from another origin.
      refute conn.resp_body =~ ~r/(src|href)="https?:\/\/(?!127\.0\.0\.1)/

      assert conn.resp_body =~ ~s(<meta name="csrf" content="#{csrf}">)
      # Data is in the HTML itself, not only fetched by script.
      assert conn.resp_body =~ "dash-managed"
      assert conn.resp_body =~ ~s(data-action="rotate" data-name="dash-managed")
      for heading <- ["Overview", "Keys", "Recent requests", "Recent media jobs", "Configuration", "Sign out"], do: assert(conn.resp_body =~ heading)

      assert {302, _, _} = request(:get, "/", nil, [])
    end

    test "escapes hostile names", %{cookie: cookie} do
      config = :persistent_term.get({ConfigStore, :config})
      hostile = ~s|<script>alert("x")</script>|
      [first | rest] = config.keys
      :persistent_term.put({ConfigStore, :config}, %{config | keys: [%{first | name: hostile} | rest]})

      {200, _, conn} = request(:get, "/", nil, [cookie])
      refute conn.resp_body =~ "<script>alert"
      assert conn.resp_body =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"
    end

    test "the overview document has the documented shape and no secrets" do
      {201, %{"key" => raw}, _} = admin(:post, "/admin/keys", %{"name" => unique("ov"), "webhook_secret" => "super-secret-signing-value"})
      {200, o, conn} = admin(:get, "/admin/overview")

      assert %{"generated_at" => _, "totals" => totals, "today" => today, "keys" => [_ | _], "requests" => requests, "jobs" => jobs, "config" => config} = o
      for part <- [totals, today], field <- ~w(requests errors input_tokens output_tokens jobs cost_usd), do: assert(is_number(part[field]))
      assert is_list(requests) and is_list(jobs)
      assert %{"upstreams" => [_ | _], "routes" => [_ | _], "media" => %{"upstreams" => _, "routes" => _, "storage" => %{"kind" => _}}, "retention" => _} = config
      assert %{"name" => _, "kind" => _, "host" => _} = hd(config["upstreams"])
      assert %{"model" => _, "strategy" => _, "targets" => [%{"upstream" => _, "model" => _, "weight" => _} | _]} = hd(config["routes"])

      for secret <- [raw, OmnigateControl.sha256_hex(raw), "super-secret-signing-value", "key_sha256", "api_key_env"], do: refute(conn.resp_body =~ secret)
      assert Enum.find(o["keys"], &(&1["has_webhook_secret"] == true))
      assert {401, _, _} = request(:get, "/admin/overview", nil, [])
    end

    test "today's figures follow the event's own day" do
      key = OmnigateControl.sha256_hex(unique("day"))
      before = Ledger.day_totals()
      old_before = Ledger.day_totals("2020-01-02")

      event = fn ts_ms -> %{"id" => unique("evt"), "key_sha256" => key, "status" => 200, "input_tokens" => 3, "output_tokens" => 4, "ts_ms" => ts_ms} end
      {:ok, _} = Ledger.record_batch([event.(System.os_time(:millisecond)), event.(1_577_923_200_000)])

      assert Ledger.day_totals().requests == before.requests + 1
      assert Ledger.day_totals("2020-01-02").requests == old_before.requests + 1
      assert Ledger.totals(key).requests == 2
      assert Ledger.stats().events == Ledger.grand_totals().requests
    end
  end

  describe "webhook addresses" do
    setup do
      config = :persistent_term.get({ConfigStore, :config})
      strict = put_in(config.media.webhooks.allow_private, false)
      :persistent_term.put({ConfigStore, :config}, strict)
      :ok
    end

    defp resolver(table) do
      Application.put_env(:omnigate_control, :webhook_resolver, fn host -> Map.get(table, host, []) end)
    end

    test "a name is accepted only if everything it resolves to is public, and the checked address is returned" do
      resolver(%{
        "public.test" => [{93, 184, 216, 34}],
        "internal.test" => [{10, 0, 0, 5}],
        "mixed.test" => [{93, 184, 216, 34}, {192, 168, 1, 9}],
        "metadata.test" => [{169, 254, 169, 254}],
        "mapped.test" => [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}]
      })

      assert {:ok, {93, 184, 216, 34}} = Webhooks.target("https://public.test/hook")
      assert :ok = Webhooks.check_url("https://public.test/hook")

      for host <- ~w(internal.test mixed.test metadata.test mapped.test) do
        assert {:error, "webhook_url resolves to a private or loopback address"} = Webhooks.target("https://#{host}/hook")
      end

      assert {:error, "webhook_url host does not resolve"} = Webhooks.target("https://nowhere.test/hook")
      # Literal addresses are judged without any lookup.
      assert {:error, _} = Webhooks.target("http://127.0.0.1:9000/hook")
      assert {:error, _} = Webhooks.target("http://[::1]/hook")
      assert {:ok, {93, 184, 216, 34}} = Webhooks.target("http://93.184.216.34/hook")
    end

    test "every attempt resolves and checks again, so a name that turns private is refused" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Application.put_env(:omnigate_control, :webhook_resolver, fn "rebind.test" ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: [{93, 184, 216, 34}], else: [{127, 0, 0, 1}]
      end)

      assert {:ok, {93, 184, 216, 34}} = Webhooks.target("http://rebind.test/hook")
      assert {:error, "webhook_url resolves to a private or loopback address"} = Webhooks.target("http://rebind.test/hook")
    end

    test "a pinned request goes to the checked address but names the host" do
      assert {"http://93.184.216.34:80/hook?a=1", headers, opts} =
               Http.pin("http://hooks.example/hook?a=1", [{"Host", "evil"}, {"x", "y"}], connect_to: {93, 184, 216, 34})

      assert headers == [{"host", "hooks.example"}, {"x", "y"}]
      refute Keyword.has_key?(opts, :tls_name) == false

      assert {"https://93.184.216.34:8443/", [{"host", "hooks.example:8443"}], opts} =
               Http.pin("https://hooks.example:8443", [], connect_to: {93, 184, 216, 34})

      # The certificate is checked against the name, not the address.
      assert opts[:tls_name] == "hooks.example"

      assert {"http://[2001:db8::1]:80/x", [{"host", "hooks.example"}], _} =
               Http.pin("http://hooks.example/x", [], connect_to: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})

      assert {"http://a.test/x", [], []} = Http.pin("http://a.test/x", [], [])
    end

    test "delivery really connects to the pinned address with the original Host header" do
      test_pid = self()

      plug = fn conn, _ ->
        send(test_pid, {:seen, Plug.Conn.get_req_header(conn, "host"), conn.request_path})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      {:ok, server} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      # "hooks.example" does not exist; only the pin makes this reachable.
      assert {:ok, %{status: 200}} =
               Http.request(:post, "http://hooks.example:#{port}/hook", [], "{}", connect_to: {127, 0, 0, 1}, timeout: 5_000)

      assert_receive {:seen, [host], "/hook"}
      assert host == "hooks.example:#{port}"
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
