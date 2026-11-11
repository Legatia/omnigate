defmodule OmnigateControl.ReceiptsTest do
  # A receipt per answer from an attested upstream: the signature flow with
  # keys made here and a signature endpoint played by this file. No quote is
  # verified in these tests (`attestation_test.exs` does that); the evidence
  # a signer is matched to is handed to a process started here, by argument.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias OmnigateControl.{ConfigStore, Receipts, Retention, Router}

  @admin "test-admin-token-0123456789"
  @key OmnigateControl.sha256_hex("og-unlimited-key")
  @other OmnigateControl.sha256_hex("og-ratelimited-key")
  @model "vendor/tee-model-1"

  defmodule Endpoint do
    @moduledoc false
    # The provider's GET /v1/signature/<id>, answering as the test scripted.
    def script(answers), do: :persistent_term.put(__MODULE__, {answers, :counters.new(1, [])})
    def calls, do: :counters.get(elem(:persistent_term.get(__MODULE__), 1), 1)
    def last_request, do: :persistent_term.get({__MODULE__, :last}, nil)

    def get(url, headers) do
      {answers, counter} = :persistent_term.get(__MODULE__)
      :counters.add(counter, 1, 1)
      :persistent_term.put({__MODULE__, :last}, {url, headers})
      n = :counters.get(counter, 1)

      case Enum.at(answers, n - 1) || List.last(answers) do
        {:ok, %{} = signature} -> {:ok, 200, [], JSON.encode!(signature)}
        {:status, status, body} -> {:ok, status, [], body}
        :down -> {:error, :econnrefused}
      end
    end
  end

  setup do
    {gw_pub, gw_priv} = :crypto.generate_key(:eddsa, :ed25519)
    {model_pub, model_priv} = :crypto.generate_key(:eddsa, :ed25519)
    {other_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)

    report = fn pub, name ->
      %{
        signing_algo: "ed25519",
        signing_address: Base.encode16(pub, case: :lower),
        status: "UpToDate",
        app_compose_sha256: String.duplicate(name, 64) |> String.slice(0, 64),
        mr_td: String.duplicate("c", 96),
        rtmr3: String.duplicate("d", 96)
      }
    end

    evidence = %{verified_at: 1_000, nonce: String.duplicate("ab", 32), gateway: report.(gw_pub, "a"), models: [report.(model_pub, "b")]}

    config =
      ConfigStore.normalize(%{
        "upstreams" => [
          %{
            "name" => "tee",
            "kind" => "openai",
            "base_url" => "https://tee.example/v1",
            "api_key_env" => "RECEIPT_TEST_KEY",
            "attestation" => %{"provider" => "near"}
          },
          %{"name" => "plain", "kind" => "openai", "base_url" => "https://plain.example", "api_key_env" => "RECEIPT_TEST_KEY"}
        ],
        "routes" => [%{"model" => "private", "targets" => [%{"upstream" => "tee", "model" => @model}, %{"upstream" => "plain", "model" => "gpt"}]}]
      })

    System.put_env("RECEIPT_TEST_KEY", "provider-key-for-tests")
    on_exit(fn -> System.delete_env("RECEIPT_TEST_KEY") end)

    keys = %{gw: gw_priv, model: model_priv, other: other_priv, other_pub: other_pub}
    {:ok, evidence: evidence, config: config, keys: keys}
  end

  # A receipts process of its own, beside the application's.
  defp start(ctx, opts \\ []) do
    n = System.unique_integer([:positive])
    name = :"receipts_test_#{n}"
    table = :"receipts_test_table_#{n}"
    path = Keyword.get(opts, :path, Path.join(System.tmp_dir!(), "omnigate-receipts-test-#{n}.json"))
    on_exit(fn -> File.rm(path) end)
    evidence = Keyword.get(opts, :evidence, ctx.evidence)

    spec =
      {Receipts,
       name: name,
       table: table,
       path: path,
       http: Endpoint,
       config: fn -> ctx.config end,
       retry_ms: Keyword.get(opts, :retry_ms, [0, 5, 5, 5]),
       evidence: fn "tee", @model, started -> if evidence && evidence.verified_at <= started, do: evidence end}

    start_supervised!(Supervisor.child_spec(spec, id: name))
    %{name: name, table: table, path: path}
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp event(id, opts \\ []) do
    request = Keyword.get(opts, :request, ~s({"model":"#{@model}","messages":[]}))
    response = Keyword.get(opts, :response, ~s({"id":"chatcmpl-#{id}","choices":[]}))

    %{
      "id" => id,
      "key_sha256" => @key,
      "route_model" => "private",
      "upstream" => Keyword.get(opts, :upstream, "tee"),
      "target_model" => @model,
      "status" => Keyword.get(opts, :status, 200),
      "stream" => Keyword.get(opts, :stream, false),
      "input_tokens" => 3,
      "output_tokens" => 5,
      "latency_ms" => 400,
      # Two seconds after the evidence was verified, unless a test says otherwise.
      "ts_ms" => Keyword.get(opts, :ts_ms, 1_002_400),
      "receipt" => Keyword.get(opts, :receipt, %{"request_sha256" => sha(request), "response_sha256" => sha(response), "completion_id" => "chatcmpl-#{id}"})
    }
  end

  defp signature(kind, priv, text, pub \\ nil) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

    %{
      "text" => text,
      "signature" => Base.encode16(:crypto.sign(:eddsa, :none, text, [priv, :ed25519]), case: :lower),
      "signing_address" => Base.encode16(pub || public, case: :lower),
      "signing_algo" => "ed25519",
      "signature_kind" => kind
    }
  end

  defp text_of(event, model \\ nil) do
    hashes = event["receipt"]["request_sha256"] <> ":" <> event["receipt"]["response_sha256"]
    if model, do: model <> ":" <> hashes, else: hashes
  end

  defp settled(server, id) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      case Receipts.get(id, server.table) do
        %{"verdict" => verdict} = r when verdict != "pending" ->
          {:halt, r}

        _ ->
          Process.sleep(5)
          {:cont, nil}
      end
    end) || flunk("receipt #{id} did not settle: #{inspect(Receipts.get(id, server.table))}")
  end

  defp offer(server, events) do
    Receipts.offer(List.wrap(events), server.name)
    Receipts.sync(server.name)
  end

  # ---- Verified ------------------------------------------------------------

  test "a model-signed answer: verified against the report checked before the request, kept across a restart", ctx do
    server = start(ctx)
    e = event("r-model")
    Endpoint.script([{:ok, signature("provider_tee", ctx.keys.model, text_of(e, @model))}])
    offer(server, e)

    r = settled(server, "r-model")
    assert r["verdict"] == "verified" and r["reason"] == nil
    assert r["signature"]["kind"] == "provider_tee"
    assert r["signature"]["text"] == @model <> ":" <> e["receipt"]["request_sha256"] <> ":" <> e["receipt"]["response_sha256"]
    assert r["attestation"]["verified_at"] == 1_000

    assert [%{"role" => "gateway", "signed_this_answer" => false}, %{"role" => "model", "signed_this_answer" => true, "tcb_status" => "UpToDate"}] =
             r["attestation"]["reports"]

    assert r["upstream"] == "tee" and r["model"] == @model and r["completion_id"] == "chatcmpl-r-model" and r["stream"] == false

    # Asked for with the upstream's key, for the completion's id, in the algorithm the reports were verified in.
    {url, headers} = Endpoint.last_request()
    assert url == "https://tee.example/v1/signature/chatcmpl-r-model?signing_algo=ed25519"
    assert {"authorization", "Bearer provider-key-for-tests"} in headers
    assert Endpoint.calls() == 1

    # No content, and nothing that identifies the key, in what is handed out.
    view = Receipts.view(r)
    assert view["object"] == "attestation.receipt"
    refute Map.has_key?(view, "key_sha256")
    refute JSON.encode!(view) =~ @key
    assert Receipts.own([@key], "r-model", server.table) == r
    assert Receipts.own([@other], "r-model", server.table) == nil
    assert Receipts.counts(server.table)["verified"] == 1

    # The same event again (at-least-once delivery) is not checked twice.
    offer(server, e)
    assert Endpoint.calls() == 1

    # It is on disk, and a new process reads it back.
    stop_supervised!(server.name)
    assert %{"receipts" => [%{"id" => "r-model", "verdict" => "verified"}]} = JSON.decode!(File.read!(server.path))
    again = start(ctx, path: server.path)
    assert %{"verdict" => "verified", "signature" => %{"kind" => "provider_tee"}} = Receipts.get("r-model", again.table)
  end

  test "a streamed answer signed by the provider's gateway: verified against the gateway's report", ctx do
    server = start(ctx)
    e = event("r-stream", stream: true, response: "data: {\"id\":\"chatcmpl-r-stream\"}\n\ndata: [DONE]\n\n")
    Endpoint.script([{:ok, signature("gateway", ctx.keys.gw, text_of(e))}])
    offer(server, e)

    r = settled(server, "r-stream")
    assert r["verdict"] == "verified" and r["signature"]["kind"] == "gateway" and r["stream"] == true
    assert [%{"role" => "gateway", "signed_this_answer" => true}, %{"role" => "model", "signed_this_answer" => false}] = r["attestation"]["reports"]
  end

  test "a signature that is recorded late is waited for, within a bound", ctx do
    server = start(ctx)
    e = event("r-late")
    Endpoint.script([{:status, 404, "{}"}, {:status, 404, "{}"}, {:ok, signature("provider_tee", ctx.keys.model, text_of(e, @model))}])
    offer(server, e)
    assert settled(server, "r-late")["verdict"] == "verified"
    assert Endpoint.calls() == 3
  end

  # ---- Not verified ----------------------------------------------------------

  test "never green without a matching, valid signature", ctx do
    server = start(ctx)

    cases = [
      # The provider signed other bytes than the ones that were sent and received.
      {"r-text", fn e -> [{:ok, signature("provider_tee", ctx.keys.model, @model <> ":" <> sha("other") <> ":" <> e["receipt"]["response_sha256"])}] end,
       "signature_text_mismatch"},
      # ... or left the model out of a model signature.
      {"r-nomodel", fn e -> [{:ok, signature("provider_tee", ctx.keys.model, text_of(e))}] end, "signature_text_mismatch"},
      # A valid signature by a key no verified report names.
      {"r-signer", fn e -> [{:ok, signature("provider_tee", ctx.keys.other, text_of(e, @model))}] end, "signer_not_verified"},
      # A gateway signature made with the model's key (and the reverse) matches the wrong report.
      {"r-crossed", fn e -> [{:ok, signature("gateway", ctx.keys.model, text_of(e))}] end, "signer_not_verified"},
      # A signature that does not verify under the key it names.
      {"r-forged",
       fn e -> [{:ok, signature("provider_tee", ctx.keys.other, text_of(e, @model), elem(:crypto.generate_key(:eddsa, :ed25519, ctx.keys.model), 0))}] end,
       "bad_response_signature"},
      # Who signed is not said, or is something unknown.
      {"r-nokind", fn e -> [{:ok, Map.delete(signature("gateway", ctx.keys.gw, text_of(e)), "signature_kind")}] end, "unknown_signature_kind"},
      {"r-oddkind", fn e -> [{:ok, signature("relay", ctx.keys.gw, text_of(e))}] end, "unknown_signature_kind"},
      # The provider says, with a 200, that there is none.
      {"r-errorcode", fn _ -> [{:ok, %{"error_code" => "STREAM_DISCONNECTED", "message" => "stream was disconnected"}}] end, "signature_unavailable"},
      # It never arrives; the provider refuses; the provider cannot be reached.
      {"r-never", fn _ -> [{:status, 404, "{}"}] end, "signature_unavailable"},
      {"r-refused", fn _ -> [{:status, 401, ~s({"error":{"message":"Invalid API key"}})}] end, "signature_unavailable"},
      {"r-down", fn _ -> [:down] end, "signature_unavailable"},
      {"r-garbage", fn _ -> [{:status, 200, "not json"}] end, "signature_unavailable"}
    ]

    log =
      capture_log(fn ->
        for {id, script, code} <- cases do
          e = event(id)
          Endpoint.script(script.(e))
          offer(server, e)
          r = settled(server, id)
          assert {id, r["verdict"], r["reason_code"]} == {id, "not_verified", code}
          assert is_binary(r["reason"]) and r["reason"] != ""

          case id do
            # Asked as often as the bound allows, and no more.
            "r-never" -> assert Endpoint.calls() == 4
            "r-down" -> assert Endpoint.calls() == 4
            # A refusal is final at once.
            "r-refused" -> assert Endpoint.calls() == 1 and r["reason"] =~ "Invalid API key"
            # What the provider returned is shown even though it did not pass.
            "r-signer" -> assert r["signature"]["signing_address"] == Base.encode16(ctx.keys.other_pub, case: :lower)
            _ -> :ok
          end
        end
      end)

    assert log =~ "NOT verified"
    assert Receipts.counts(server.table) == %{"verified" => 0, "not_verified" => length(cases), "pending" => 0}
  end

  test "a key named by two verified reports is ambiguous, not verified", ctx do
    [model] = ctx.evidence.models
    server = start(ctx, evidence: %{ctx.evidence | models: [model, %{model | app_compose_sha256: String.duplicate("e", 64)}]})
    e = event("r-twice")
    Endpoint.script([{:ok, signature("provider_tee", ctx.keys.model, text_of(e, @model))}])

    capture_log(fn ->
      offer(server, e)
      settled(server, "r-twice")
    end)

    r = settled(server, "r-twice")
    assert {r["verdict"], r["reason_code"]} == {"not_verified", "signer_not_verified"}
    assert r["reason"] =~ "2 verified reports"
  end

  test "what cannot be checked is not asked for, and says why", ctx do
    server = start(ctx)
    Endpoint.script([{:status, 404, "{}"}])

    capture_log(fn ->
      # The request started before any attestation had been verified: a later report proves nothing about it.
      offer(server, event("r-early", ts_ms: 999_000))
      assert %{"verdict" => "not_verified", "reason_code" => "no_prior_attestation", "attestation" => nil} = settled(server, "r-early")

      # The answer named no id (or one that is not a plain token).
      no_id = event("r-noid")
      offer(server, put_in(no_id, ["receipt", "completion_id"], nil))
      assert %{"verdict" => "not_verified", "reason_code" => "no_completion_id"} = settled(server, "r-noid")
      odd_id = event("r-oddid")
      offer(server, put_in(odd_id, ["receipt", "completion_id"], "../v1/models"))
      assert %{"reason_code" => "no_completion_id"} = settled(server, "r-oddid")

      # The control plane does not have the provider's key.
      System.delete_env("RECEIPT_TEST_KEY")
      offer(server, event("r-nokey"))
      assert %{"verdict" => "not_verified", "reason_code" => "api_key_missing", "reason" => reason} = settled(server, "r-nokey")
      assert reason =~ "RECEIPT_TEST_KEY"
    end)

    assert Endpoint.calls() == 0
  end

  test "events that are not answers from an attested upstream leave no receipt", ctx do
    server = start(ctx)
    Endpoint.script([{:status, 404, "{}"}])

    offer(server, [
      # No receipt part at all (every ordinary request), or an empty one.
      Map.delete(event("r-none"), "receipt"),
      Map.put(event("r-null"), "receipt", nil),
      # An upstream without an attestation setting, whatever the data plane claims.
      event("r-plain", upstream: "plain"),
      event("r-unknown", upstream: "elsewhere"),
      # An answer that is an error.
      event("r-500", status: 502),
      # Hashes that are not hashes; an id that is not a plain token.
      event("r-badhash", receipt: %{"request_sha256" => "zz", "response_sha256" => String.duplicate("a", 64), "completion_id" => "c"}),
      event("r-upper", receipt: %{"request_sha256" => String.duplicate("A", 64), "response_sha256" => String.duplicate("a", 64), "completion_id" => "c"}),
      event("has space"),
      %{"receipt" => %{}},
      "not an event"
    ])

    assert Receipts.recent(50, server.table) == []
    assert Endpoint.calls() == 0
    # (Nor does a broken batch stop usage from being recorded.)
    assert Receipts.offer([nil, 1, %{"receipt" => %{"x" => 1}}], server.name) == :ok
  end

  test "an unfinished check does not survive a restart as pending; old receipts are pruned", ctx do
    path = Path.join(System.tmp_dir!(), "omnigate-receipts-test-pending-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "receipts" => [
          %{"id" => "r-pending", "verdict" => "pending", "created" => 2_000, "upstream" => "tee", "model" => @model, "key_sha256" => @key},
          %{"id" => "r-old", "verdict" => "verified", "created" => 1_000, "upstream" => "tee", "model" => @model, "key_sha256" => @key}
        ]
      })
    )

    server = capture_log(fn -> send(self(), {:server, start(ctx, path: path)}) end) && receive(do: ({:server, s} -> s))
    assert %{"verdict" => "not_verified", "reason_code" => "not_checked", "reason" => reason} = Receipts.get("r-pending", server.table)
    assert reason =~ "restarted"

    assert Receipts.prune(1_500, server.name) == 1
    assert Receipts.get("r-old", server.table) == nil
    assert Receipts.get("r-pending", server.table) != nil
    assert Receipts.prune(1_500, server.name) == 0

    # A file that is not what this module wrote is not fatal.
    stop_supervised!(server.name)
    File.write!(path, "{{{")
    log = capture_log(fn -> send(self(), {:server, start(ctx, path: path)}) end)
    assert log =~ "could not be read"
    assert_received {:server, fresh}
    assert Receipts.recent(10, fresh.table) == []
  end

  # ---- The application's own ---------------------------------------------------

  defp call(method, path, headers) do
    conn = Enum.reduce(headers, conn(method, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = Router.call(conn, Router.init([]))
    {conn.status, JSON.decode!(conn.resp_body)}
  end

  defp internal(key), do: [{"x-omnigate-internal", OmnigateControl.internal_token()}, {"x-omnigate-key-sha256", key}]
  defp admin, do: [{"authorization", "Bearer " <> @admin}]

  test "the key that made the request reads its receipt; another key and an unknown id get the same 404" do
    id = "r-http-#{System.unique_integer([:positive])}"

    receipt = %{
      "id" => id,
      "key_sha256" => @key,
      "created" => System.os_time(:second),
      "started" => System.os_time(:second),
      "upstream" => "tee",
      "model" => @model,
      "verdict" => "verified",
      "request_sha256" => String.duplicate("1", 64),
      "response_sha256" => String.duplicate("2", 64)
    }

    :ets.insert(:omnigate_receipts, {id, receipt})
    on_exit(fn -> :ets.delete(:omnigate_receipts, id) end)

    assert {200, %{"object" => "attestation.receipt", "id" => ^id, "verdict" => "verified"} = view} =
             call(:get, "/internal/v1/attestations/#{id}", internal(@key))

    refute Map.has_key?(view, "key_sha256") or Map.has_key?(view, "key")
    assert {404, %{"error" => %{"code" => "receipt_not_found"}}} = call(:get, "/internal/v1/attestations/#{id}", internal(@other))
    assert {404, %{"error" => %{"code" => "receipt_not_found"}}} = call(:get, "/internal/v1/attestations/nope", internal(@key))
    assert {401, _} = call(:get, "/internal/v1/attestations/#{id}", internal("deadbeef"))
    assert {401, _} = call(:get, "/internal/v1/attestations/#{id}", [{"x-omnigate-key-sha256", @key}])

    # The operator sees it with the key's name, and the counts.
    assert {200, %{"id" => ^id, "key" => "unlimited"}} = call(:get, "/admin/receipts/#{id}", admin())
    assert {404, _} = call(:get, "/admin/receipts/nope", admin())
    assert {200, %{"receipts" => list, "counts" => %{"verified" => n}}} = call(:get, "/admin/receipts?limit=500", admin())
    assert Enum.any?(list, &(&1["id"] == id)) and n >= 1
    assert {status, _} = call(:get, "/admin/receipts", [])
    assert status in [401, 302]

    {conn_status, metrics} = {200, Router.call(put_req_header(conn(:get, "/metrics"), "authorization", "Bearer " <> @admin), Router.init([])).resp_body}
    assert conn_status == 200 and metrics =~ ~s(omnigate_receipts{verdict="verified"})
  end

  test "a usage batch offers its receipts; the ledger keeps no part of them; retention has a setting" do
    id = "r-batch-#{System.unique_integer([:positive])}"
    # (No attested upstream in the test config: offered, and passed over.)
    conn = conn(:post, "/internal/usage/batch", JSON.encode!(%{"events" => [event(id)]})) |> put_req_header("content-type", "application/json")
    conn = conn |> put_req_header("x-omnigate-internal", OmnigateControl.internal_token()) |> Router.call(Router.init([]))
    assert conn.status == 200
    assert Receipts.get(id) == nil

    {200, page} = call(:get, "/admin/events?limit=1000", admin())
    recorded = Enum.find(page["events"], &(&1["id"] == id))
    assert recorded != nil
    refute Map.has_key?(recorded, "receipt")

    assert ConfigStore.normalize(%{}).retention.receipts_days == 30
    assert ConfigStore.normalize(%{"retention" => %{"receipts_days" => 0}}).retention.receipts_days == 0
    assert_raise ArgumentError, ~r/receipts_days/, fn -> ConfigStore.normalize(%{"retention" => %{"receipts_days" => -1}}) end
    assert %{receipts: 0} = Retention.sweep(%{receipts_days: 30}, System.os_time(:millisecond))
  end
end
