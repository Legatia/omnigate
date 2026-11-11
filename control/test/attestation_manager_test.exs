defmodule OmnigateControl.AttestationManagerTest do
  @moduledoc """
  The attestation setting, the manager that keeps attested upstreams
  verified, and what the rest of the control plane shows of it.

  The manager under test is one started here, beside the application's, with
  an HTTP module that answers from the saved real report
  (`test/fixtures/attestation`) and Intel's collateral as saved with it.
  Those are handed over as start arguments; nothing in the config or the
  environment can do the same, which the last test checks.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{Attestation, ConfigStore, Privacy, Router}
  alias OmnigateControl.Attestation.{Manager, Tdx}

  @fixtures Path.expand("fixtures/attestation", __DIR__)
  @admin "test-admin-token-0123456789"

  defmodule FakeHttp do
    @moduledoc false
    # Answers attestation requests as the test's current script says.
    def get(url, _headers) do
      case :persistent_term.get({__MODULE__, :mode}) do
        :report ->
          {:ok, 200, [], :persistent_term.get({__MODULE__, :report})}

        {:status, status, body} ->
          {:ok, status, [], body}

        {:body, body} ->
          {:ok, 200, [], body}

        :down ->
          {:error, :econnrefused}

        {:by_model, map} ->
          map |> Enum.find_value({:ok, 503, [], "no provider"}, fn {model, answer} -> if String.contains?(url, URI.encode_www_form(model)), do: answer end)
      end
    end

    def post(_url, _headers, _body), do: {:error, :not_scripted}
    def mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
  end

  defp fx(name), do: File.read!(Path.join(@fixtures, name))

  setup_all do
    :persistent_term.put({FakeHttp, :report}, fx("report.json"))
    :ok
  end

  setup do
    model = fx("report_model.txt")
    sets = JSON.decode!(fx("collateral.json"))

    collateral = fn quote ->
      with {:ok, {fmspc, ca}} <- Tdx.collateral_key(quote), do: {:ok, Map.fetch!(sets, fmspc <> "/" <> ca)}
    end

    check_opts = [http: FakeHttp, collateral: collateral, nonce: fx("report_nonce.txt"), now: String.to_integer(fx("verified_at.txt"))]
    FakeHttp.mode(:report)
    {:ok, model: model, check_opts: check_opts}
  end

  defp config(model, attestation \\ %{"provider" => "near", "gpu" => "skip"}, extra_targets \\ []) do
    ConfigStore.normalize(%{
      "upstreams" => [
        %{"name" => "near", "kind" => "openai", "base_url" => "https://attested.example/v1", "api_key_env" => "NEAR_AI_API_KEY", "attestation" => attestation},
        %{"name" => "plain", "kind" => "openai", "base_url" => "https://plain.example", "api_key_env" => "PLAIN_KEY"}
      ],
      "routes" => [
        %{"model" => "private", "targets" => [%{"upstream" => "near", "model" => model}, %{"upstream" => "plain", "model" => "gpt"}] ++ extra_targets}
      ]
    })
  end

  defp start(ctx, config) do
    name = :"attestation_test_#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> config end)
    spec = {Manager, name: name, tick: false, check_opts: ctx.check_opts, config: fn -> Agent.get(agent, & &1) end}
    start_supervised!(Supervisor.child_spec(spec, id: name))
    {name, agent}
  end

  # ---- The setting ---------------------------------------------------------

  test "the setting: defaults, and everything not understood is refused" do
    assert %{provider: "near", accepted_tcb: ["UpToDate"], gpu: "if_present", max_age_s: 900, measurements: lists} =
             Attestation.normalize!(%{"provider" => "near"}, "x")

    assert Map.keys(lists) |> Enum.sort() == ~w(gateway_app_compose_sha256 gateway_mr_td model_app_compose_sha256 model_mr_td)
    assert Enum.all?(Map.values(lists), &(&1 == []))
    assert Attestation.normalize!(nil, "x") == nil

    sha = String.duplicate("AB", 32)

    assert %{measurements: %{"model_app_compose_sha256" => [lower]}} =
             Attestation.normalize!(%{"provider" => "near", "measurements" => %{"model_app_compose_sha256" => [sha]}}, "x")

    assert lower == String.downcase(sha)

    for bad <- [
          true,
          %{},
          %{"provider" => "intel"},
          %{"provider" => "near", "skip" => true},
          %{"provider" => "near", "verify" => false},
          %{"provider" => "near", "accepted_tcb" => []},
          %{"provider" => "near", "accepted_tcb" => ["Fine"]},
          %{"provider" => "near", "accepted_tcb" => "UpToDate"},
          %{"provider" => "near", "gpu" => "maybe"},
          %{"provider" => "near", "gpu" => true},
          %{"provider" => "near", "max_age_s" => 59},
          %{"provider" => "near", "max_age_s" => 86_401},
          %{"provider" => "near", "max_age_s" => "900"},
          %{"provider" => "near", "measurements" => []},
          %{"provider" => "near", "measurements" => %{"other" => []}},
          %{"provider" => "near", "measurements" => %{"gateway_mr_td" => [sha]}},
          %{"provider" => "near", "measurements" => %{"model_app_compose_sha256" => ["zz"]}},
          %{"provider" => "near", "measurements" => %{"model_app_compose_sha256" => sha}}
        ] do
      assert_raise ArgumentError, ~r/^upstream "u": "attestation"/, fn -> Attestation.normalize!(bad, "upstream \"u\"") end
    end
  end

  test "a config with a bad attestation setting does not load; a good one names what to attest", %{model: model} do
    assert_raise ArgumentError, ~r/upstream "near": "attestation"/, fn -> config(model, %{"provider" => "near", "max_age_s" => 1}) end

    wanted = Attestation.wanted(config(model, %{"provider" => "near"}, [%{"upstream" => "near", "model" => model}]))
    # Once per (upstream, model), and only for the attested upstream.
    assert [%{upstream: "near", model: ^model, base_url: "https://attested.example/v1", setting: %{max_age_s: 900}}] = wanted
  end

  # ---- The manager ---------------------------------------------------------

  test "a pair starts pending, verifies, and the verdict reaches the snapshot view", ctx do
    {name, _} = start(ctx, config(ctx.model))
    assert Manager.all(name) == []
    Manager.sync(name)
    # Pending the moment it is known, before any check has answered.
    assert %{verified: false} = Manager.for_snapshot("near", ctx.model, System.os_time(:second), name) || %{verified: false}

    entry = Manager.verify_now("near", ctx.model, name)
    assert entry.state == :verified
    assert entry.evidence.gateway.status == "UpToDate"
    assert [%{model: model}] = entry.evidence.models
    assert model == ctx.model
    now = System.os_time(:second)
    assert entry.until == entry.checked_at + 900
    assert entry.next_check_at <= entry.checked_at + 450

    assert %{verified: true, max_age_s: 900, tcb: "UpToDate", since: since} = Manager.for_snapshot("near", ctx.model, now, name)
    assert since == entry.verified_since
    # Too old is not verified, whatever the state says.
    assert %{verified: false, tcb: nil, since: 0} = Manager.for_snapshot("near", ctx.model, entry.until, name)
    # Other targets carry nothing.
    assert Manager.for_snapshot("plain", "gpt", now, name) == nil
    assert Manager.for_snapshot("near", "another-model", now, name) == nil

    view = Attestation.view(entry, now)
    assert view.verified and view.state == "verified" and view.evidence.gateway.tcb_status == "UpToDate"
    assert view.evidence.nonce == File.read!(Path.join(@fixtures, "report_nonce.txt"))
    assert [%{gpu: "skipped", signing_algo: "ed25519", app_compose_sha256: <<_::binary-64>>}] = view.evidence.models
    assert is_binary(JSON.encode!(view))
    assert Attestation.view(entry, entry.until).state == "failed"
  end

  test "evidence that does not hold withdraws the pair at once, with the reason", ctx do
    {name, _} = start(ctx, config(ctx.model))
    Manager.sync(name)
    assert Manager.verify_now("near", ctx.model, name).state == :verified

    # The same report against another nonce: not fresh.
    stale = ctx.check_opts |> Keyword.put(:nonce, String.duplicate("ab", 32))
    {name2, _} = start(%{ctx | check_opts: stale}, config(ctx.model))
    Manager.sync(name2)
    entry = Manager.verify_now("near", ctx.model, name2)
    assert entry.state == :failed and entry.reason_code == "nonce_mismatch"
    assert entry.reason =~ "does not carry our nonce"
    assert %{verified: false} = Manager.for_snapshot("near", ctx.model, System.os_time(:second), name2)

    # A pass, then evidence that fails: withdrawn although the pass is recent.
    FakeHttp.mode(
      {:body, JSON.encode!(%{"gateway_attestation" => %{"intel_quote" => "00", "request_nonce" => File.read!(Path.join(@fixtures, "report_nonce.txt"))}})}
    )

    entry = Manager.verify_now("near", ctx.model, name)
    assert entry.state == :failed
    assert entry.reason =~ "the provider's gateway"
    refute Manager.verified?(entry, System.os_time(:second))
    # The evidence of the earlier pass is kept for the record, not for the verdict.
    assert %{verified: false, tcb: nil} = Manager.for_snapshot("near", ctx.model, System.os_time(:second), name)
  end

  test "a check that cannot get its inputs leaves a recent pass standing, and never creates one", ctx do
    FakeHttp.mode(:down)
    {name, _} = start(ctx, config(ctx.model))
    Manager.sync(name)
    entry = Manager.verify_now("near", ctx.model, name)
    assert entry.state == :failed and entry.reason_code == "report_unavailable"

    FakeHttp.mode(:report)
    assert Manager.verify_now("near", ctx.model, name).state == :verified

    for mode <- [:down, {:status, 503, "no provider found that supports attestation reports"}, {:status, 429, ""}] do
      FakeHttp.mode(mode)
      entry = Manager.verify_now("near", ctx.model, name)
      assert entry.state == :verified
      assert is_binary(entry.reason)
      # It is tried again soon, and the pass still ends when it would have.
      assert entry.next_check_at - entry.last_attempt_at <= 120
      refute Manager.verified?(entry, entry.until)
    end

    # Garbage is not "unavailable": it is an answer, and a wrong one.
    FakeHttp.mode({:body, "<html>welcome</html>"})
    assert %{state: :failed, reason_code: "bad_report"} = Manager.verify_now("near", ctx.model, name)
  end

  test "a model the provider has no attestation for is refused; its neighbour is not", ctx do
    report = {:ok, 200, [], File.read!(Path.join(@fixtures, "report.json"))}
    FakeHttp.mode({:by_model, %{ctx.model => report}})
    {name, _} = start(ctx, config(ctx.model, %{"provider" => "near", "gpu" => "skip"}, [%{"upstream" => "near", "model" => "openai/gpt-5"}]))
    Manager.sync(name)
    assert Manager.verify_now("near", ctx.model, name).state == :verified
    relayed = Manager.verify_now("near", "openai/gpt-5", name)
    assert relayed.state == :failed and relayed.reason =~ "no attestation report (HTTP 503"
    assert length(Manager.all(name)) == 2
  end

  test "the operator's policy: statuses, GPU evidence and measurements", ctx do
    {:ok, evidence} =
      Attestation.check("https://attested.example", ctx.model, Attestation.normalize!(%{"provider" => "near", "gpu" => "skip"}, "t"), ctx.check_opts)

    gateway_hash = evidence.gateway.app_compose_sha256
    [%{app_compose_sha256: model_hash, mr_td: model_mr_td}] = evidence.models

    check = fn setting ->
      Attestation.check(
        "https://attested.example/v1",
        ctx.model,
        Attestation.normalize!(Map.merge(%{"provider" => "near", "gpu" => "skip"}, setting), "t"),
        ctx.check_opts
      )
    end

    assert {:ok, _} =
             check.(%{
               "measurements" => %{
                 "gateway_app_compose_sha256" => [gateway_hash],
                 "model_app_compose_sha256" => [String.duplicate("00", 32), model_hash],
                 "model_mr_td" => [model_mr_td]
               }
             })

    other = String.duplicate("11", 32)

    assert {:error, {:measurement_not_allowed, {"gateway_app_compose_sha256", ^gateway_hash}}} =
             check.(%{"measurements" => %{"gateway_app_compose_sha256" => [other]}})

    assert {:error, {:measurement_not_allowed, {"model_app_compose_sha256", ^model_hash}}} =
             check.(%{"measurements" => %{"model_app_compose_sha256" => [other]}})

    assert {:error, {:measurement_not_allowed, {"model_mr_td", _}}} = check.(%{"measurements" => %{"model_mr_td" => [String.duplicate("22", 48)]}})
    assert Attestation.describe({:measurement_not_allowed, {"model_mr_td", "ab"}}) =~ "not on the configured allowlist"

    assert {:error, {:gateway_report_failed, {:tcb_status_not_accepted, {"UpToDate", _}}}} = check.(%{"accepted_tcb" => ["OutOfDate"]})
    # The fixture's GPU evidence carries the fixture's nonce; NVIDIA is not
    # reachable through the scripted HTTP module, and "required" does not
    # mean "assumed".
    assert {:error, {:model_report_failed, {0, {:gpu_verdict_unavailable, _}}}} = check.(%{"gpu" => "require"})
    assert Attestation.transient?({:model_report_failed, {0, {:gpu_verdict_unavailable, :x}}})
    refute Attestation.transient?({:gateway_report_failed, {:nonce_mismatch, :echo}})
  end

  test "pairs follow the config: dropped when no longer routed, reset when the upstream changes", ctx do
    {name, agent} = start(ctx, config(ctx.model))
    Manager.sync(name)
    assert Manager.verify_now("near", ctx.model, name).state == :verified

    # Another policy on the same upstream: what was found answered another question.
    Agent.update(agent, fn _ -> config(ctx.model, %{"provider" => "near", "gpu" => "skip", "max_age_s" => 120}) end)
    FakeHttp.mode(:down)
    Manager.sync(name)
    assert %{max_age_s: 120, checked_at: nil} = Manager.status("near", ctx.model, name)
    refute Manager.verified?(Manager.status("near", ctx.model, name), System.os_time(:second))

    Agent.update(agent, fn _ -> config(ctx.model, nil) end)
    Manager.sync(name)
    assert Manager.all(name) == []
    assert Manager.verify_now("near", ctx.model, name) == nil
  end

  # ---- What the application shows ------------------------------------------

  defp admin(method, path, body \\ nil) do
    conn = conn(method, path, body && JSON.encode!(body)) |> put_req_header("authorization", "Bearer " <> @admin)
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
    Router.call(conn, Router.init([]))
  end

  test "admin API and metrics: nothing to attest in a config without attested upstreams" do
    conn = admin(:get, "/admin/attestations")
    assert conn.status == 200
    assert %{"attestations" => [], "checks" => %{"ok" => _, "failed" => _, "unavailable" => _}} = JSON.decode!(conn.resp_body)

    assert admin(:post, "/admin/attestations/verify", %{"upstream" => "openai", "model" => "gpt-4o"}).status == 404
    assert admin(:post, "/admin/attestations/verify", %{"upstream" => 1}).status == 400
    anonymous = Router.call(conn(:get, "/admin/attestations"), Router.init([]))
    assert anonymous.status in [401, 302]

    metrics = admin(:get, "/metrics").resp_body
    assert metrics =~ "# TYPE omnigate_attestation_verified gauge"
    assert metrics =~ ~s(omnigate_attestation_checks_total{outcome="ok"})

    # The feature is opt-in: no page, no nav link, nothing to send through.
    assert admin(:get, "/private-chat").status == 404
    assert admin(:get, "/admin/private-chat/state").status == 404
    assert admin(:post, "/admin/private-chat/send", %{"model" => "x", "messages" => []}).status == 404
    refute admin(:get, "/").resp_body =~ "private-chat"

    # No target in the snapshot claims an attestation.
    refute Router.snapshot() |> JSON.encode!() |> String.contains?("attestation")
  end

  test "privacy: attested is a part of its own, and `true` does not switch it on" do
    assert {:ok, %{attested: false, no_store: true}} = Privacy.normalize(true)
    assert {:ok, %{attested: true, no_store: false, redact: [], unlink: false, encrypt_to: nil} = p} = Privacy.normalize(%{"attested" => true})
    assert Privacy.attested?(%{privacy: p})
    refute Privacy.attested?(%{privacy: nil})
    assert Privacy.summary(p) == "attested"
    assert Privacy.for_data_plane(p) == %{no_store: false, redact: [], unlink: false, attested: true}
    assert Privacy.view(p).attested
    assert {:error, "privacy.attested must be true or false"} = Privacy.normalize(%{"attested" => "yes"})
    assert {:ok, nil} = Privacy.normalize(%{"attested" => false})
    # A setting stored before the part existed.
    assert %{attested: false} = Privacy.load(%{"no_store" => true})
    assert Privacy.for_data_plane(Privacy.load(%{"no_store" => true})) == %{no_store: true, redact: [], unlink: false, attested: false}
    assert Privacy.header("attested, no-store") == {:ok, true}
    assert Privacy.header("attested") == {:ok, false}
  end

  test "nothing outside a test can replace the trust anchor or skip a check" do
    # The trust anchor reaches verification only as a function argument.
    sources = Path.wildcard(Path.expand("../lib/**/*.ex", __DIR__)) |> Enum.map(&{&1, File.read!(&1)})

    for {path, text} <- sources, String.contains?(text, "trusted_root_der") do
      refute text =~ ~r/(System\.get_env|Application\.get_env|fetch_env)[^\n]*trusted_root/, path
    end

    # The application's own manager is started without check options.
    app = File.read!(Path.expand("../lib/omnigate_control/application.ex", __DIR__))
    assert app =~ ~r/^\s+OmnigateControl\.Attestation\.Manager,$/m
    # And a config cannot carry any: unknown settings are refused (first test).
    assert_raise ArgumentError, fn -> Attestation.normalize!(%{"provider" => "near", "trusted_root_der" => "x"}, "u") end
  end
end
