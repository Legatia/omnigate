defmodule OmnigateControl.RetentionMetricsTest do
  # Swaps the live config and sweeps shared stores, so it must not run
  # alongside other tests.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{ConfigStore, Ledger, Retention, Router, Storage}
  alias OmnigateControl.Jobs.Store

  @admin "test-admin-token-0123456789"
  @internal "test-internal-token"
  @day_ms 86_400_000

  setup do
    original = ConfigStore.get()
    previous_token = System.get_env("OMNIGATE_INTERNAL_TOKEN")
    System.put_env("OMNIGATE_INTERNAL_TOKEN", @internal)

    on_exit(fn ->
      put_config(original)
      if previous_token, do: System.put_env("OMNIGATE_INTERNAL_TOKEN", previous_token), else: System.delete_env("OMNIGATE_INTERNAL_TOKEN")
    end)

    {:ok, original: original}
  end

  defp put_config(config), do: :persistent_term.put({ConfigStore, :config}, config)
  defp call(conn), do: Router.call(conn, Router.init([]))
  defp unique, do: System.unique_integer([:positive])
  defp job_id, do: "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

  # ---------------------------------------------------------------- config

  describe "config for the data plane" do
    test "keys, routes and targets carry models, strategy and weight, with defaults" do
      config =
        ConfigStore.normalize(%{
          "keys" => [%{"name" => "all", "key" => "k1"}, %{"name" => "some", "key" => "k2", "models" => ["chat", "image"]}],
          "upstreams" => [%{"name" => "u", "kind" => "openai", "base_url" => "http://x", "api_key_env" => "K"}],
          "routes" => [
            %{"model" => "chat", "targets" => [%{"upstream" => "u", "model" => "a"}]},
            %{"model" => "spread", "strategy" => "round_robin", "targets" => [%{"upstream" => "u", "model" => "a"}, %{"upstream" => "u", "model" => "b"}]},
            %{"model" => "split", "strategy" => "weighted", "targets" => [%{"upstream" => "u", "model" => "a", "weight" => 9}, %{"upstream" => "u", "model" => "b", "weight" => 0}]}
          ]
        })

      assert [%{models: nil}, %{models: ["chat", "image"]}] = config.keys
      assert [%{strategy: "failover", targets: [%{weight: 1}]}, %{strategy: "round_robin"}, %{strategy: "weighted", targets: [%{weight: 9}, %{weight: 0}]}] = config.routes
      assert config.retention == %{jobs_days: 0, ledger_ids_days: 0}
    end

    test "bad values are refused with a message that names the problem" do
      route = fn extra, target_extra ->
        %{"routes" => [Map.merge(%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "a"}, target_extra)]}, extra)]}
      end

      assert_raise ArgumentError, ~r/"strategy" must be one of failover, round_robin, weighted, got "fastest"/, fn ->
        ConfigStore.normalize(route.(%{"strategy" => "fastest"}, %{}))
      end

      assert_raise ArgumentError, ~r/"weight" must be a non-negative integer/, fn -> ConfigStore.normalize(route.(%{}, %{"weight" => -1})) end
      assert_raise ArgumentError, ~r/"weight" must be a non-negative integer/, fn -> ConfigStore.normalize(route.(%{}, %{"weight" => 1.5})) end
      assert_raise ArgumentError, ~r/needs at least one target with a weight above 0/, fn -> ConfigStore.normalize(route.(%{"strategy" => "weighted"}, %{"weight" => 0})) end
      assert_raise ArgumentError, ~r/"models" must be a list of model names/, fn -> ConfigStore.normalize(%{"keys" => [%{"name" => "k", "key" => "x", "models" => "chat"}]}) end
      assert_raise ArgumentError, ~r/retention.jobs_days must be a number of days/, fn -> ConfigStore.normalize(%{"retention" => %{"jobs_days" => "30"}}) end
    end

    test "the snapshot sent to data planes carries the fields", %{original: original} do
      extra =
        ConfigStore.normalize(%{
          "keys" => [%{"name" => "limited", "key" => "snap-key", "models" => ["chat"]}],
          "upstreams" => [%{"name" => "u", "kind" => "openai", "base_url" => "http://x", "api_key_env" => "K"}],
          "routes" => [%{"model" => "split", "strategy" => "weighted", "targets" => [%{"upstream" => "u", "model" => "a", "weight" => 3}]}]
        })

      put_config(%{original | keys: extra.keys, upstreams: extra.upstreams, routes: extra.routes})

      conn = conn(:get, "/internal/config") |> put_req_header("x-omnigate-internal", @internal) |> call()
      assert conn.status == 200
      snapshot = JSON.decode!(conn.resp_body)

      assert [%{"name" => "limited", "models" => ["chat"], "rpm" => 0, "blocked" => false}] = snapshot["keys"]
      assert [%{"model" => "split", "strategy" => "weighted", "targets" => [%{"upstream" => "u", "model" => "a", "weight" => 3} = target]}] = snapshot["routes"]
      # Prices stay on the control plane.
      refute Map.has_key?(target, "price_in_per_mtok")

      # A key without a list is sent as null, meaning every model.
      put_config(%{original | keys: [%{hd(extra.keys) | models: nil}]})
      conn = conn(:get, "/internal/config") |> put_req_header("x-omnigate-internal", @internal) |> call()
      assert [%{"models" => nil}] = JSON.decode!(conn.resp_body)["keys"]
    end
  end

  # ---------------------------------------------------------------- model limits

  test "a key limited to some models cannot create jobs for others", %{original: original} do
    key = fn name, models ->
      %{name: name, key_sha256: OmnigateControl.sha256_hex(name), budget_usd: nil, rpm: 0, models: models, webhook_secret: nil}
    end

    put_config(%{original | keys: [key.("limited", ["some-other-model"]), key.("open", nil)]})

    post = fn name, model ->
      conn(:post, "/internal/v1/jobs", JSON.encode!(%{"model" => model, "input" => %{"prompt" => "x"}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-omnigate-internal", @internal)
      |> put_req_header("x-omnigate-key-sha256", OmnigateControl.sha256_hex(name))
      |> call()
    end

    before = length(Store.all())
    conn = post.("limited", "no-such-media-model")
    assert conn.status == 403
    assert %{"error" => %{"type" => "model_not_allowed", "message" => message}} = JSON.decode!(conn.resp_body)
    assert message =~ "no-such-media-model"
    assert length(Store.all()) == before

    # Allowed by the list, so it gets as far as route lookup (404: no such route).
    assert post.("limited", "some-other-model").status == 404
    # A key without a list is not restricted.
    assert post.("open", "no-such-media-model").status == 404
  end

  # ---------------------------------------------------------------- retention

  describe "retention" do
    setup %{original: original} do
      dir = Application.fetch_env!(:omnigate_control, :media_dir)
      put_config(%{original | media: %{original.media | storage: %{kind: "local", dir: dir, url_ttl_s: 600}}})
      {:ok, dir: dir}
    end

    defp finished_job(finished_ms, extra) do
      Map.merge(
        %{
          "id" => job_id(),
          "status" => "succeeded",
          "model" => "retention-test",
          "input" => %{},
          "outputs" => [],
          "cost_usd" => 0.0,
          "cached" => false,
          "attempts" => [],
          "webhook" => nil,
          "key_sha256" => "retention-key",
          "created_ms" => finished_ms - 1_000,
          "finished_ms" => finished_ms,
          "ledgered" => true
        },
        extra
      )
    end

    defp store!(job) do
      {:ok, job} = Store.create(job)
      job
    end

    defp with_file(job, dir, name) do
      path = Path.join([dir, job["id"], name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "data")
      {Map.put(job, "outputs", [%{"name" => name, "storage" => "local", "content_type" => "image/png", "bytes" => 4}]), path}
    end

    test "old finished jobs go, with their files, cache entries and idempotency keys; everything else stays", %{dir: dir} do
      now = System.os_time(:millisecond)
      cache_key = "cache-#{unique()}"
      idem = "idem-#{unique()}"

      {old, old_file} = finished_job(now - 40 * @day_ms, %{"cache_key" => cache_key, "idempotency_key" => idem}) |> with_file(dir, "out-0.png")
      old = store!(old)
      {recent, recent_file} = finished_job(now - 5 * @day_ms, %{}) |> with_file(dir, "out-0.png")
      recent = store!(recent)
      # Old, but not finished: never removed, whatever its age.
      running = store!(finished_job(now - 40 * @day_ms, %{"status" => "running", "finished_ms" => nil, "created_ms" => now - 40 * @day_ms}))
      # Old and finished, but its webhook is still being retried.
      retrying = store!(finished_job(now - 40 * @day_ms, %{"webhook" => %{"url" => "http://x", "status" => "retrying", "attempts" => 1}}))
      # Old and finished, but its cost has not reached the ledger yet.
      unbilled = store!(finished_job(now - 40 * @day_ms, %{"ledgered" => false}))

      assert {old["id"], old["finished_ms"]} == Store.cache_lookup(cache_key)
      assert {:existing, _} = Store.create(%{old | "id" => job_id()})

      # Nothing is removed unless retention is configured.
      assert %{jobs: 0, files: 0, ledger_ids: 0} = Retention.sweep(%{jobs_days: 0, ledger_ids_days: 0}, now)
      assert Store.get(old["id"])

      result = Retention.sweep(%{jobs_days: 30, ledger_ids_days: 0}, now)
      assert result.jobs >= 1 and result.files >= 1

      assert Store.get(old["id"]) == nil
      refute File.exists?(old_file)
      refute File.exists?(Path.dirname(old_file))
      # No dangling cache hit, and the idempotency key is free again.
      assert Store.cache_lookup(cache_key) == nil
      assert {:ok, reused} = Store.create(finished_job(now, %{"idempotency_key" => idem}))

      assert Store.get(recent["id"])
      assert File.exists?(recent_file)
      for kept <- [running, retrying, unbilled], do: assert(Store.get(kept["id"]), "#{kept["id"]} should have been kept")

      # The log lost the job too: one line per remaining job, all readable.
      path = Application.fetch_env!(:omnigate_control, :jobs_path)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      logged = Enum.map(lines, &JSON.decode!(&1)["id"])
      refute old["id"] in logged
      assert Enum.sort(logged) == Store.all() |> Enum.map(& &1["id"]) |> Enum.sort()
      refute File.exists?(path <> ".compact")

      # And it replays: restart the store from that file.
      ids_before = Store.all() |> Enum.map(& &1["id"]) |> Enum.sort()
      :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Store)
      {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Store)
      assert Store.all() |> Enum.map(& &1["id"]) |> Enum.sort() == ids_before
      assert Store.get(old["id"]) == nil
      assert Store.get(recent["id"])["outputs"] == recent["outputs"]

      # Leave nothing unfinished behind for other tests.
      for job <- [running, retrying, unbilled, reused, recent] do
        Store.update(job["id"], &Map.merge(&1, %{"status" => "canceled", "webhook" => nil, "ledgered" => true, "finished_ms" => now - 400 * @day_ms}))
      end

      Retention.sweep(%{jobs_days: 30, ledger_ids_days: 0}, now)
      assert Store.get(recent["id"]) == nil
      refute File.exists?(recent_file)
    end

    test "delete_local only removes well-formed local outputs", %{dir: dir} do
      File.mkdir_p!(dir)
      outside = Path.join(dir, "keep-#{unique()}.txt")
      File.write!(outside, "keep")
      job = %{"id" => job_id(), "outputs" => [%{"name" => "../" <> Path.basename(outside), "storage" => "local"}, %{"name" => "x.png", "storage" => "s3", "key" => "k"}]}
      assert Storage.delete_local(job) == 0
      assert File.exists?(outside)
      assert Storage.delete_local(%{job | "id" => "../etc"}) == 0
      File.rm!(outside)
    end

    test "ledger ids are forgotten after their window; totals stay; a fresh duplicate is still refused" do
      key = "ledger-prune-#{unique()}"
      event = fn id -> %{"id" => id, "key_sha256" => key, "status" => 200, "input_tokens" => 10, "output_tokens" => 5} end
      old_id = "old-#{unique()}"
      new_id = "new-#{unique()}"

      assert {:ok, %{accepted: 1}} = Ledger.record_batch([event.(old_id)])
      Process.sleep(20)
      boundary = System.os_time(:millisecond)
      Process.sleep(20)
      assert {:ok, %{accepted: 1}} = Ledger.record_batch([event.(new_id)])

      totals = Ledger.totals(key)
      assert totals.requests == 2
      ids_before = Ledger.stats().dedup_ids

      # "Now" is one day after the boundary, with a one-day window: everything
      # recorded before the boundary is past it.
      result = Retention.sweep(%{jobs_days: 0, ledger_ids_days: 1}, boundary + @day_ms)
      assert result.ledger_ids >= 1
      assert Ledger.stats().dedup_ids == ids_before - result.ledger_ids

      # Spend is untouched by pruning.
      assert Ledger.totals(key) == totals
      # Still inside the window: refused as a duplicate.
      assert {:ok, %{accepted: 0, duplicates: 1}} = Ledger.record_batch([event.(new_id)])
      # The documented cost of a short window: a resend this late counts again.
      assert {:ok, %{accepted: 1, duplicates: 0}} = Ledger.record_batch([event.(old_id)])
      assert Ledger.totals(key).requests == 3
    end

    test "the sweeper is running under the supervisor" do
      assert is_pid(Process.whereis(Retention))
      assert {Retention, _pid, :worker, _} = List.keyfind(Supervisor.which_children(OmnigateControl.Supervisor), Retention, 0)
    end
  end

  # ---------------------------------------------------------------- metrics

  describe "GET /metrics" do
    test "needs the admin token" do
      conn = conn(:get, "/metrics") |> call()
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      # The data planes' token is not enough.
      assert (conn(:get, "/metrics") |> put_req_header("x-omnigate-internal", @internal) |> call()).status == 401
    end

    test "serves well-formed Prometheus text with per-key series", %{original: original} do
      name = ~s(team "a"\\b\nline)
      hash = OmnigateControl.sha256_hex("metrics-#{unique()}")
      key = %{name: name, key_sha256: hash, budget_usd: 0.5, rpm: 0, models: nil, webhook_secret: nil}
      plain = %{name: "plain-#{unique()}", key_sha256: OmnigateControl.sha256_hex("plain-#{unique()}"), budget_usd: nil, rpm: 0, models: nil, webhook_secret: nil}
      put_config(%{original | keys: [key, plain]})

      {:ok, %{accepted: 2}} =
        Ledger.record_batch([
          %{"id" => "m-#{unique()}", "key_sha256" => hash, "status" => 200, "input_tokens" => 11, "output_tokens" => 6},
          %{"id" => "m-#{unique()}", "key_sha256" => hash, "status" => 502, "input_tokens" => 0, "output_tokens" => 0}
        ])

      conn = conn(:get, "/metrics") |> put_req_header("authorization", "Bearer " <> @admin) |> call()
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
      body = conn.resp_body

      # Every line is a comment or `name{labels} value`; every family has HELP and TYPE.
      sample = ~r/^(omnigate_[a-z_]+)(\{([a-z_]+="(\\.|[^"\\])*",?)+\})? -?[0-9][0-9.e+-]*$/
      lines = String.split(body, "\n", trim: true)
      for line <- lines, not String.starts_with?(line, "#"), do: assert(line =~ sample, "malformed sample line: #{line}")

      families = for "# TYPE " <> rest <- lines, do: rest |> String.split(" ") |> hd()
      helped = for "# HELP " <> rest <- lines, do: rest |> String.split(" ") |> hd()
      assert families == helped
      assert families == Enum.uniq(families)
      for line <- lines, not String.starts_with?(line, "#"), do: assert(hd(Regex.run(~r/^[a-z_]+/, line)) in families)
      for "# TYPE " <> rest <- lines, [family, "counter"] <- [String.split(rest, " ")], do: assert(String.ends_with?(family, "_total"), family)

      label = ~s(key="team \\"a\\"\\\\b\\nline")
      assert body =~ "omnigate_key_requests_total{#{label}} 2\n"
      assert body =~ "omnigate_key_errors_total{#{label}} 1\n"
      assert body =~ "omnigate_key_input_tokens_total{#{label}} 11\n"
      assert body =~ "omnigate_key_output_tokens_total{#{label}} 6\n"
      assert body =~ "omnigate_key_jobs_total{#{label}} 0\n"
      assert body =~ "omnigate_key_cost_usd_total{#{label}} 0.0\n"
      assert body =~ "omnigate_key_budget_usd{#{label}} 0.5\n"
      assert body =~ "omnigate_key_blocked{#{label}} 0\n"
      # No budget, so no budget series for that key, but it is not blocked.
      refute body =~ ~s(omnigate_key_budget_usd{key="#{plain.name}"})
      assert body =~ ~s(omnigate_key_blocked{key="#{plain.name}"} 0\n)

      for status <- ~w(queued running succeeded failed canceled), do: assert(body =~ ~r/^omnigate_jobs\{status="#{status}"\} \d+$/m)
      for state <- ~w(waiting pending retrying delivered failed), do: assert(body =~ ~r/^omnigate_webhooks\{state="#{state}"\} \d+$/m)

      assert body =~ ~r/^omnigate_build_info\{version="\d+\.\d+\.\d+"\} 1$/m
      assert body =~ ~r/^omnigate_uptime_seconds \d/m
      assert body =~ ~r/^omnigate_config_reloads_total \d+$/m
      assert body =~ ~r/^omnigate_config_last_reload_timestamp_seconds \d{10}(\.\d+)?$/m
      assert [_, events] = Regex.run(~r/^omnigate_ledger_events_total (\d+)$/m, body)
      assert String.to_integer(events) >= 2
      assert body =~ ~r/^omnigate_ledger_dedup_ids \d+$/m
    end

    test "a key over its budget shows as blocked", %{original: original} do
      hash = OmnigateControl.sha256_hex("metrics-blocked-#{unique()}")
      name = "over-#{unique()}"
      put_config(%{original | keys: [%{name: name, key_sha256: hash, budget_usd: 0.0, rpm: 0, models: nil, webhook_secret: nil}]})
      conn = conn(:get, "/metrics") |> put_req_header("authorization", "Bearer " <> @admin) |> call()
      assert conn.resp_body =~ ~s(omnigate_key_blocked{key="#{name}"} 1\n)
    end
  end
end
