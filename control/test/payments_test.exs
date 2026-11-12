defmodule OmnigateControl.PaymentsTest do
  # Payments for prepaid credit: the settings, the NEAR Intents adapter (its
  # quote signature against real answers, its refusals, its status mapping),
  # and the flow from a quote to a credited key. The provider is played by
  # `FakeIntents`, in process; nothing here opens a connection.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{Audit, ConfigStore, Keys, Payments, Router}
  alias OmnigateControl.Payments.NearIntents

  @admin "test-admin-token-0123456789"
  @moduletag :capture_log
  @fixtures Path.expand("fixtures/payments", __DIR__)
  @usdc "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"

  defmodule FakeIntents do
    @moduledoc false
    # The 1Click API as the adapter sees it: tokens, quote, status. `mode`
    # makes it misbehave; `outcomes` says what became of a deposit address.
    @usdc "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"

    def start do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, _} = Agent.start_link(fn -> %{private: private, quotes: %{}, outcomes: %{}, mode: nil, seen: [], headers: [], calls: 0} end, name: __MODULE__)
      NearIntents.base58_encode(public)
    end

    def set(field, value), do: Agent.update(__MODULE__, &Map.put(&1, field, value))
    def get(field), do: Agent.get(__MODULE__, &Map.fetch!(&1, field))
    def outcome(address, outcome), do: Agent.update(__MODULE__, &put_in(&1, [:outcomes, address], outcome))

    def request(method, url, headers, body, _opts) do
      uri = URI.parse(url)
      Agent.update(__MODULE__, &%{&1 | headers: headers, calls: &1.calls + 1})

      case {get(:mode), method, uri.path} do
        {:down, _, _} -> {:error, :econnrefused}
        {:html, _, _} -> {:ok, %{status: 200, headers: %{}, body: "<html>maintenance</html>"}}
        {:unauthorized, _, _} -> json(401, %{"message" => "Unauthorized"})
        {_, :get, "/v0/tokens"} -> json(200, tokens())
        {mode, :post, "/v0/quote"} -> make_quote(JSON.decode!(body), mode)
        {_, :get, "/v0/status"} -> status(URI.decode_query(uri.query || ""))
        {_, :post, "/v0/deposit/submit"} -> submit(JSON.decode!(body))
        _ -> json(404, %{"message" => "not found"})
      end
    end

    defp tokens do
      [
        %{"assetId" => "nep141:wrap.near", "decimals" => 24, "blockchain" => "near", "symbol" => "wNEAR", "price" => 4.0},
        %{"assetId" => @usdc, "decimals" => 6, "blockchain" => "near", "symbol" => "USDC", "price" => 1.0},
        %{"assetId" => "nep141:eth.omft.near", "decimals" => 18, "blockchain" => "eth", "symbol" => "ETH", "price" => 2000.0},
        # Listed twice, as the real service lists Bitcoin; a quote for the
        # first is signed as if it were for the second.
        %{"assetId" => "nep141:btc.omft.near", "decimals" => 8, "blockchain" => "btc", "symbol" => "BTC", "price" => 74_000.0},
        %{"assetId" => "1cs_v1:btc:native:coin", "decimals" => 8, "blockchain" => "btc", "symbol" => "BTC(OMNI)", "price" => 74_000.0},
        %{"symbol" => "BROKEN"}
      ]
    end

    defp make_quote(body, mode) do
      Agent.update(__MODULE__, &%{&1 | seen: [body | &1.seen]})

      cond do
        body["refundTo"] == "nowhere" ->
          json(400, %{"message" => "refundTo is not valid"})

        body["originAsset"] == "nep141:bsc.omft.near" ->
          json(400, %{"message" => "Temporary swap limits: minimum swap amount is $1,000"})

        true ->
          address = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

          quote =
            %{"amountIn" => "1262500000000000000000000", "amountInFormatted" => "1.2625", "amountInUsd" => "5.05", "minAmountIn" => "1250000000000000000000000"}
            |> Map.merge(%{"amountOut" => body["amount"], "amountOutFormatted" => "5.0", "amountOutUsd" => "4.99", "minAmountOut" => body["amount"]})
            |> Map.merge(%{"timeEstimate" => 20, "refundFee" => "0", "withdrawFee" => "4652"})
            |> Map.merge(if(body["dry"], do: %{}, else: %{"depositAddress" => address, "deadline" => body["deadline"], "timeWhenInactive" => body["deadline"]}))
            |> Map.merge(if(mode == :memo, do: %{"depositMemo" => "777"}, else: %{}))
            |> Map.merge(if(mode == :wrong_amount, do: %{"amountOut" => "1"}, else: %{}))

          request = body |> Map.merge(%{"depositMode" => "SIMPLE", "quoteWaitingTimeMs" => 0, "appFees" => [%{"recipient" => "fees", "fee" => 25}]})
          request = if mode == :wrong_recipient, do: Map.put(request, "recipient", "someone-else.near"), else: request
          answer = sign(%{"quote" => quote, "quoteRequest" => request, "timestamp" => "2026-11-11T20:00:00.000Z", "correlationId" => "c-1"})

          answer =
            if body["originAsset"] == "nep141:btc.omft.near",
              do: Map.put(answer, "signature", sign(put_in(answer, ["quoteRequest", "originAsset"], "1cs_v1:btc:native:coin"))["signature"]),
              else: answer

          answer =
            if mode == :bad_signature, do: Map.put(answer, "signature", "ed25519:" <> NearIntents.base58_encode(:crypto.strong_rand_bytes(64))), else: answer

          unless body["dry"], do: Agent.update(__MODULE__, &put_in(&1, [:quotes, address], answer))
          json(201, answer)
      end
    end

    def sign(answer) do
      signature = :crypto.sign(:eddsa, :none, NearIntents.signed_text(answer), [get(:private), :ed25519])
      Map.put(answer, "signature", "ed25519:" <> NearIntents.base58_encode(signature))
    end

    defp status(%{"depositAddress" => address}) do
      case get(:quotes)[address] do
        nil ->
          json(404, %{"message" => "Deposit address #{address} not found"})

        answer ->
          {raw, details, tamper} =
            case get(:outcomes)[address] do
              nil -> {"PENDING_DEPOSIT", %{}, nil}
              {raw, details} -> {raw, details, nil}
              {raw, details, tamper} -> {raw, details, tamper}
            end

          answer =
            case tamper do
              :recipient -> answer |> put_in(["quoteRequest", "recipient"], "someone-else.near") |> sign()
              :signature -> put_in(answer, ["quote", "amountIn"], "1")
              :address -> answer |> put_in(["quote", "depositAddress"], "0x00") |> sign()
              nil -> answer
            end

          details = Map.merge(%{"intentHashes" => [], "nearTxHashes" => [], "originChainTxHashes" => [], "destinationChainTxHashes" => []}, details)

          json(200, %{"correlationId" => "c-2", "quoteResponse" => answer, "status" => raw, "updatedAt" => "2026-11-11T20:01:00.000Z", "swapDetails" => details})
      end
    end

    defp submit(body) do
      Agent.update(__MODULE__, &%{&1 | seen: [{:submitted, body} | &1.seen]})
      json(200, %{"ok" => true})
    end

    defp json(status, body), do: {:ok, %{status: status, headers: %{"content-type" => "application/json"}, body: JSON.encode!(body)}}
  end

  setup do
    original = :persistent_term.get({ConfigStore, :config})
    public = FakeIntents.start()

    config =
      %{"provider" => "near_intents", "recipient" => "operator.near", "public_key" => public, "base_url" => "http://intents.test", "poll_interval_s" => 1}
      |> Payments.normalize!()
      |> Map.put(:http, &FakeIntents.request/5)

    :persistent_term.put({ConfigStore, :config}, Map.put(original, :payments, config))
    :persistent_term.erase({Payments, :assets})

    on_exit(fn ->
      for k <- Keys.managed(), do: Keys.delete(k.name)
      :persistent_term.put({ConfigStore, :config}, original)
      :persistent_term.erase({Payments, :assets})
      :sys.replace_state(Payments, &%{&1 | payments: []})
      System.delete_env("PAYMENTS_TEST_JWT")
    end)

    {:ok, config: config, original: original}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp prepaid(budget \\ 0) do
    name = unique("payer")
    {:ok, key, raw} = Keys.create(%{"name" => name, "budget_usd" => budget})
    {key, OmnigateControl.sha256_hex(raw)}
  end

  defp key(name), do: Enum.find(Keys.managed(), &(&1.name == name))

  defp request(method, path, headers, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end) |> Router.call(Router.init([]))

    json =
      case JSON.decode(conn.resp_body || "") do
        {:ok, value} -> value
        _ -> nil
      end

    {conn.status, json}
  end

  defp gateway(method, path, hash, body \\ nil),
    do: request(method, path, [{"x-omnigate-internal", OmnigateControl.internal_token()}, {"x-omnigate-key-sha256", hash}], body)

  defp admin(method, path, body \\ nil), do: request(method, path, [{"authorization", "Bearer " <> @admin}], body)

  defp pay(hash, attrs \\ %{}) do
    gateway(:post, "/internal/v1/payments", hash, Map.merge(%{"amount_usd" => 5, "asset" => "nep141:wrap.near", "refund_to" => "payer.near"}, attrs))
  end

  defp delivered(units), do: %{"amountOut" => units, "destinationChainTxHashes" => [%{"hash" => "NearTx1", "explorerUrl" => "https://x"}]}

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # ================================================================== settings

  describe "the \"payments\" section" do
    test "absent means off; given, it has its defaults" do
      assert Payments.normalize!(nil) == nil
      assert %{payments: nil} = ConfigStore.normalize(%{})

      assert %{
               provider: "near_intents",
               recipient: "letobias.near",
               settle_asset: @usdc,
               settle_decimals: 6,
               slippage_bps: 100,
               min_usd: 1.0,
               max_usd: 10_000.0,
               quote_ttl_s: 1800,
               poll_interval_s: 15,
               jwt_env: nil,
               base_url: "https://1click.chaindefuser.com",
               public_key: "reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc"
             } = Payments.normalize!(%{"provider" => "near_intents", "recipient" => "letobias.near"})
    end

    test "what is not understood is refused" do
      ok = %{"provider" => "near_intents", "recipient" => "operator.near"}

      for bad <- [
            %{"recipient" => "operator.near"},
            %{"provider" => "stripe", "recipient" => "operator.near"},
            %{"provider" => "near_intents"},
            Map.put(ok, "recipient", "Not An Account"),
            Map.put(ok, "min_usd", 0),
            Map.merge(ok, %{"min_usd" => 50, "max_usd" => 10}),
            Map.put(ok, "quote_ttl_s", 10),
            Map.put(ok, "slippage_bps", 5000),
            # Gone with the two kinds of credit: all credit earns the bonus.
            Map.put(ok, "bonus_eligible", true),
            Map.put(ok, "settle_asset", "not an asset"),
            Map.put(ok, "settle_decimals", 99),
            Map.put(ok, "public_key", "0OIl"),
            Map.put(ok, "base_url", "ftp://x"),
            Map.put(ok, "jwt_env", 5),
            Map.put(ok, "recipent", "typo.near"),
            "near_intents"
          ] do
        assert_raise ArgumentError, fn -> Payments.normalize!(bad) end
      end
    end
  end

  # ============================================================ the quote signature

  describe "1Click's quote signature" do
    test "a real dry quote (11 November 2026) verifies under the pinned key, and not when a field is changed" do
      answer = @fixtures |> Path.join("dry_quote.json") |> File.read!() |> JSON.decode!()
      config = Payments.normalize!(%{"provider" => "near_intents", "recipient" => "example.near"})
      assert NearIntents.signed_text(answer) == "87A749pYnPzWrNmetsCxiXckNBchYQkn9jtanhCcuuQa"
      assert NearIntents.signed(answer, config) == :ok
      assert NearIntents.signed(put_in(answer, ["quote", "amountIn"], "1"), config) == {:error, :bad_signature}
      assert NearIntents.signed(put_in(answer, ["quoteRequest", "recipient"], "thief.near"), config) == {:error, :bad_signature}
      assert NearIntents.signed(Map.put(answer, "timestamp", "2026-11-11T19:59:18.362Z"), config) == {:error, :bad_signature}
      # Fields outside the signed set do not matter.
      assert NearIntents.signed(Map.put(answer, "correlationId", "other"), config) == :ok
    end

    test "a quote with a deposit address (the SDK's own test vector) verifies under the key it was signed with" do
      answer = @fixtures |> Path.join("staging_quote.json") |> File.read!() |> JSON.decode!()
      staging = %{public_key: "5J5tkaxyPoR3Q9S8LXfo5bWnXK5Z2bctJ4mB9gENh7co"}
      assert NearIntents.signed_text(answer) == "XS2Ej8EbPHKiDBfxaFY3y6az5pCDb8eh4bSdAErvZy7"
      assert NearIntents.signed(answer, staging) == :ok
      # The address a payer would send funds to is inside the signature.
      assert NearIntents.signed(put_in(answer, ["quote", "depositAddress"], "bc1qattackerattackerattackerattackerattac"), staging) == {:error, :bad_signature}
      # Another key (the production one) did not sign it.
      assert NearIntents.signed(answer, Payments.normalize!(%{"provider" => "near_intents", "recipient" => "example.near"})) == {:error, :bad_signature}

      for bad <- [nil, "", "ed25519:", "ed25519:0OIl", "secp256k1:abc", "ed25519:" <> String.duplicate("1", 10), 5] do
        assert NearIntents.signed(Map.put(answer, "signature", bad), staging) == {:error, :bad_signature}
      end

      assert NearIntents.signed(Map.delete(answer, "timestamp"), staging) == {:error, :bad_signature}
      assert NearIntents.signed(%{}, staging) == {:error, :bad_signature}
    end

    test "an asset listed twice: a real Bitcoin quote is signed under its other id, and only that one" do
      answer = @fixtures |> Path.join("btc_dry_quote.json") |> File.read!() |> JSON.decode!()
      config = Payments.normalize!(%{"provider" => "near_intents", "recipient" => "example.near"})
      assert answer["quoteRequest"]["originAsset"] == "nep141:btc.omft.near"
      assert NearIntents.signed(answer, config) == {:error, :bad_signature}
      assert NearIntents.signed(answer, config, "1cs_v1:btc:native:coin") == :ok
      assert NearIntents.signed(answer, config, "nep141:eth.omft.near") == {:error, :bad_signature}
      assert NearIntents.signed(put_in(answer, ["quoteRequest", "recipient"], "thief.near"), config, "1cs_v1:btc:native:coin") == {:error, :bad_signature}
    end

    test "Base58 both ways" do
      for bytes <- [<<0>>, <<0, 0, 1>>, "hello", :crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(64)] do
        assert NearIntents.base58(NearIntents.base58_encode(bytes)) == {:ok, bytes}
      end

      assert NearIntents.base58_encode("hello") == "Cn8eVZg"
      assert NearIntents.base58("0") == :error
      assert NearIntents.base58("") == :error
      assert NearIntents.base58(String.duplicate("1", 201)) == :error
    end
  end

  # ================================================================== the adapter

  describe "the adapter" do
    test "assets are the provider's list, without entries that are not assets", %{config: config} do
      assert {:ok, assets} = NearIntents.assets(config)
      assert Enum.map(assets, & &1["symbol"]) == ["wNEAR", "USDC", "ETH", "BTC", "BTC(OMNI)"]
      assert %{"asset" => "nep141:wrap.near", "chain" => "near", "decimals" => 24, "price_usd" => 4.0} = hd(assets)
    end

    test "a quote asks for an exact amount of the settle asset to the operator, refunds to the payer", %{config: config} do
      deadline = System.os_time(:second) + 600
      assert {:ok, quoted} = NearIntents.quote(config, %{amount_usd: 5.0, asset: "nep141:wrap.near", refund_to: "payer.near", deadline: deadline, dry: false})

      assert %{
               "deposit_address" => "0x" <> _,
               "deposit_memo" => nil,
               "amount_in" => "1262500000000000000000000",
               "amount_in_formatted" => "1.2625",
               "time_estimate_s" => 20
             } = quoted

      assert %{"signature" => "ed25519:" <> _, "timestamp" => _} = quoted["proof"]

      assert [sent] = FakeIntents.get(:seen)

      assert %{
               "dry" => false,
               "swapType" => "EXACT_OUTPUT",
               "amount" => "5000000",
               "originAsset" => "nep141:wrap.near",
               "destinationAsset" => @usdc,
               "recipient" => "operator.near",
               "recipientType" => "DESTINATION_CHAIN",
               "refundTo" => "payer.near",
               "refundType" => "ORIGIN_CHAIN",
               "depositType" => "ORIGIN_CHAIN",
               "slippageTolerance" => 100
             } = sent

      assert {:ok, at, _} = DateTime.from_iso8601(sent["deadline"])
      assert DateTime.to_unix(at) == deadline

      # A dry quote has no address and creates nothing.
      assert {:ok, %{"deposit_address" => nil, "amount_in" => _}} =
               NearIntents.quote(config, %{amount_usd: 5.0, asset: "nep141:wrap.near", refund_to: "payer.near", deadline: deadline, dry: true})

      # A chain that needs a memo: it is part of the instructions.
      FakeIntents.set(:mode, :memo)

      assert {:ok, %{"deposit_memo" => "777"}} =
               NearIntents.quote(config, %{amount_usd: 5.0, asset: "nep141:wrap.near", refund_to: "payer.near", deadline: deadline, dry: false})
    end

    test "a quote that is not signed by the provider, or does not repeat what was asked, is not used", %{config: config} do
      request = %{amount_usd: 5.0, asset: "nep141:wrap.near", refund_to: "payer.near", deadline: System.os_time(:second) + 600, dry: false}

      FakeIntents.set(:mode, :bad_signature)
      assert {:error, 502, "payment_provider_error", message} = NearIntents.quote(config, request)
      assert message =~ "not signed"

      FakeIntents.set(:mode, :wrong_recipient)
      assert {:error, 502, "payment_provider_error", message} = NearIntents.quote(config, request)
      assert message =~ "recipient"

      FakeIntents.set(:mode, :wrong_amount)
      assert {:error, 502, "payment_provider_error", message} = NearIntents.quote(config, request)
      assert message =~ "amountOut"

      # A key that is not the provider's: the same quote is refused.
      FakeIntents.set(:mode, nil)
      assert {:error, 502, "payment_provider_error", _} = NearIntents.quote(%{config | public_key: "reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc"}, request)
    end

    test "a quote signed under the asset's other listed id is accepted, under an id that is not its alias refused", %{config: config} do
      request = %{amount_usd: 5.0, asset: "nep141:btc.omft.near", refund_to: "bc1qpayer", deadline: System.os_time(:second) + 600, dry: false}
      # Without knowing the other id, the signature does not fit what was asked.
      assert {:error, 502, "payment_provider_error", _} = NearIntents.quote(config, request)
      assert {:error, 502, "payment_provider_error", _} = NearIntents.quote(config, Map.put(request, :aliases, ["nep141:eth.omft.near"]))
      assert {:ok, quoted} = NearIntents.quote(config, Map.put(request, :aliases, ["1cs_v1:btc:native:coin"]))
      assert quoted["proof"]["origin_asset"] == "1cs_v1:btc:native:coin"
      # ... and its status is checked the same way.
      payment = Map.merge(quoted, %{"recipient" => "operator.near", "settle_asset" => @usdc})
      assert {:ok, %{state: :awaiting_deposit}} = NearIntents.status(config, payment)
      assert {:error, :bad_signature} = NearIntents.status(config, put_in(payment, ["proof", "origin_asset"], "nep141:btc.omft.near"))
      # An asset asked for and signed under its own id says so.
      assert {:ok, %{"proof" => %{"origin_asset" => "nep141:wrap.near"}}} =
               NearIntents.quote(config, %{request | asset: "nep141:wrap.near", refund_to: "payer.near"})
    end

    test "the provider's refusals keep their words; its outages are ours to name", %{config: config} do
      request = %{amount_usd: 5.0, asset: "nep141:wrap.near", refund_to: "payer.near", deadline: System.os_time(:second) + 600, dry: false}
      assert {:error, 400, "payment_quote_refused", message} = NearIntents.quote(config, %{request | refund_to: "nowhere"})
      assert message =~ "refundTo is not valid"
      assert {:error, 400, "payment_quote_refused", message} = NearIntents.quote(config, %{request | asset: "nep141:bsc.omft.near"})
      assert message =~ "minimum swap amount is $1,000"

      FakeIntents.set(:mode, :down)
      assert {:error, 503, "payment_provider_unavailable", _} = NearIntents.quote(config, request)
      assert {:error, 503, "payment_provider_unavailable", _} = NearIntents.assets(config)
      FakeIntents.set(:mode, :html)
      assert {:error, 502, "payment_provider_error", _} = NearIntents.quote(config, request)
      assert {:error, 502, "payment_provider_error", _} = NearIntents.assets(config)
      FakeIntents.set(:mode, :unauthorized)
      assert {:error, 502, "payment_provider_error", message} = NearIntents.quote(config, request)
      assert message =~ "credentials"
    end

    test "a partner token is sent when its variable is set, and only then", %{config: config} do
      assert {:ok, _} = NearIntents.assets(config)
      refute Enum.any?(FakeIntents.get(:headers), fn {name, _} -> name == "authorization" end)
      System.put_env("PAYMENTS_TEST_JWT", "partner-token")
      assert {:ok, _} = NearIntents.assets(%{config | jwt_env: "PAYMENTS_TEST_JWT"})
      assert {"authorization", "Bearer partner-token"} in FakeIntents.get(:headers)
    end

    test "a status is believed only about the quote it was asked about", %{config: config} do
      {:ok, quoted} =
        NearIntents.quote(config, %{amount_usd: 5.0, asset: "nep141:wrap.near", refund_to: "payer.near", deadline: System.os_time(:second) + 600, dry: false})

      payment = Map.merge(quoted, %{"recipient" => "operator.near", "settle_asset" => @usdc})
      address = quoted["deposit_address"]

      assert {:ok, %{state: :awaiting_deposit, raw: "PENDING_DEPOSIT", delivered_usd: nil}} = NearIntents.status(config, payment)

      for {raw, state} <- [
            {"KNOWN_DEPOSIT_TX", :processing},
            {"PROCESSING", :processing},
            {"INCOMPLETE_DEPOSIT", :awaiting_deposit},
            {"REFUNDED", :refunded},
            {"FAILED", :failed},
            {"SOMETHING_NEW", :processing}
          ] do
        FakeIntents.outcome(address, {raw, %{"refundReason" => "PARTIAL_DEPOSIT"}})
        assert {:ok, %{state: ^state, raw: ^raw, delivered_usd: nil}} = NearIntents.status(config, payment)
      end

      FakeIntents.outcome(address, {"SUCCESS", delivered("4990000")})
      assert {:ok, %{state: :settled, delivered_usd: 4.99, tx: ["NearTx1"]}} = NearIntents.status(config, payment)
      # Success without an amount is not a settlement yet.
      FakeIntents.outcome(address, {"SUCCESS", %{}})
      assert {:ok, %{state: :processing, delivered_usd: nil}} = NearIntents.status(config, payment)
      FakeIntents.outcome(address, {"SUCCESS", %{"amountOut" => "-5"}})
      assert {:ok, %{state: :processing}} = NearIntents.status(config, payment)

      # Re-signed by the provider's key or not: an answer about another quote is not ours.
      for {tamper, what} <- [recipient: "signature", address: "depositAddress", signature: "signature"] do
        FakeIntents.outcome(address, {"SUCCESS", delivered("5000000"), tamper})
        assert {:error, reason} = NearIntents.status(config, payment)
        assert reason in [{:mismatch, what}, :bad_signature]
      end

      # A quote of ours for another recipient, a deposit address the provider does not know, an outage.
      FakeIntents.outcome(address, {"SUCCESS", delivered("5000000")})
      assert {:error, {:mismatch, "recipient"}} = NearIntents.status(config, %{payment | "recipient" => "other.near"})
      assert {:error, {:http, 404, _}} = NearIntents.status(config, %{payment | "deposit_address" => "0xunknown"})
      FakeIntents.set(:mode, :down)
      assert {:error, :econnrefused} = NearIntents.status(config, payment)
    end
  end

  # ============================================================ from a quote to credit

  describe "a payment" do
    test "starts with deposit instructions, and credits the key once it has settled", %{config: _} do
      {key, hash} = prepaid()
      assert Keys.over_budget?(key)

      # A key with nothing left can still ask: this is what the endpoints are for.
      assert {200, %{"assets" => [%{"asset" => "nep141:wrap.near", "symbol" => "wNEAR", "chain" => "near"} | _] = assets}} =
               gateway(:get, "/internal/v1/payments/assets", hash)

      assert length(assets) == 5
      assert {200, %{"assets" => [%{"symbol" => "ETH"}]}} = gateway(:get, "/internal/v1/payments/assets?chain=eth", hash)
      assert {200, %{"assets" => [%{"symbol" => "USDC"}]}} = gateway(:get, "/internal/v1/payments/assets?symbol=usdc", hash)

      assert {201, payment} = pay(hash)

      assert %{
               "id" => "pay_" <> _ = id,
               "status" => "awaiting_deposit",
               "amount_usd" => 5.0,
               "credited_usd" => nil,
               "provider" => "near_intents",
               "refund_to" => "payer.near",
               "deposit" => %{
                 "address" => "0x" <> _ = address,
                 "memo" => nil,
                 "asset" => "nep141:wrap.near",
                 "symbol" => "wNEAR",
                 "chain" => "near",
                 "amount" => "1.2625",
                 "amount_units" => "1262500000000000000000000"
               }
             } = payment

      assert is_binary(payment["deadline"])
      refute Map.has_key?(payment, "key")
      assert {200, ^payment} = gateway(:get, "/internal/v1/payments/#{id}", hash)
      assert {200, %{"payments" => [^payment]}} = gateway(:get, "/internal/v1/payments", hash)

      # Nothing has arrived: asked, and still waiting; nothing credited.
      :ok = Payments.poll_now()
      assert {200, %{"status" => "awaiting_deposit", "provider_status" => "PENDING_DEPOSIT"}} = gateway(:get, "/internal/v1/payments/#{id}", hash)
      assert key(key.name).budget_usd == 0.0

      FakeIntents.outcome(address, {"PROCESSING", %{}})
      :ok = Payments.poll_now()
      assert {200, %{"status" => "processing", "credited_usd" => nil}} = gateway(:get, "/internal/v1/payments/#{id}", hash)

      FakeIntents.outcome(address, {"SUCCESS", delivered("5000000")})
      :ok = Payments.poll_now()
      assert {200, %{"status" => "settled", "credited_usd" => 5.0, "tx" => ["NearTx1"], "detail" => nil}} = gateway(:get, "/internal/v1/payments/#{id}", hash)
      assert key(key.name).budget_usd == 5.0
      refute Keys.over_budget?(key(key.name))

      # Credited as coming from this provider, under the deposit address.
      reference = "near_intents:" <> address
      assert [%{"reference" => ^reference, "amount_usd" => 5.0, "source" => "near_intents"}] = Keys.topups(10, key.name)
      assert %{balance_usd: 5.0} = OmnigateControl.Credits.view(key(key.name), 0.0)

      # Seen settled again, however often: credited once.
      :ok = Payments.poll_now()

      :sys.replace_state(Payments, fn state ->
        %{state | payments: Enum.map(state.payments, &Map.merge(&1, %{"status" => "processing", "credited_usd" => nil}))}
      end)

      :ok = Payments.poll_now()
      assert key(key.name).budget_usd == 5.0
      assert length(Keys.topups(10, key.name)) == 1
      assert {200, %{"status" => "settled", "credited_usd" => 5.0}} = gateway(:get, "/internal/v1/payments/#{id}", hash)

      # ... also when the provider then reports another amount: what was credited stands.
      :sys.replace_state(Payments, fn state ->
        %{state | payments: Enum.map(state.payments, &Map.merge(&1, %{"status" => "processing", "credited_usd" => nil}))}
      end)

      FakeIntents.outcome(address, {"SUCCESS", delivered("4000000")})
      :ok = Payments.poll_now()
      assert key(key.name).budget_usd == 5.0
      assert {200, %{"status" => "settled", "credited_usd" => 5.0, "detail" => nil}} = gateway(:get, "/internal/v1/payments/#{id}", hash)

      # In the audit log, in the admin listing with its reference, in the metrics.
      wait_until(fn -> Enum.any?(Audit.recent(100), &(&1["action"] == "payment.settle" and &1["target"] == key.name)) end)

      assert %{"auth" => "system", "payment" => %{"id" => ^id, "reference" => ^reference, "credited_usd" => 5.0}} =
               Enum.find(Audit.recent(100), &(&1["action"] == "payment.settle" and &1["target"] == key.name))

      assert {200,
              %{
                "configured" => true,
                "payments" => [%{"id" => ^id, "key" => name, "reference" => ^reference, "recipient" => "operator.near"}]
              }} = admin(:get, "/admin/payments")

      assert name == key.name
      metrics = conn(:get, "/metrics") |> put_req_header("authorization", "Bearer " <> @admin) |> Router.call(Router.init([])) |> Map.fetch!(:resp_body)
      assert metrics =~ ~s(omnigate_payments{status="settled"} 1)
      assert metrics =~ "omnigate_payments_credited_usd 5.0"
    end

    test "paid with an asset the provider lists twice (and signs under its other id): quoted, settled, credited" do
      {key, hash} = prepaid()

      assert {201, %{"id" => id, "deposit" => %{"address" => address, "symbol" => "BTC", "chain" => "btc"}}} =
               pay(hash, %{"asset" => "nep141:btc.omft.near", "refund_to" => "bc1qpayer"})

      FakeIntents.outcome(address, {"SUCCESS", delivered("5000000")})
      :ok = Payments.poll_now()
      assert {200, %{"status" => "settled", "credited_usd" => 5.0}} = gateway(:get, "/internal/v1/payments/#{id}", hash)
      assert key(key.name).budget_usd == 5.0
      # What it would take, without starting anything: no address, nothing stored.
      assert {200, %{"amount" => "1.2625", "symbol" => "BTC", "amount_usd" => 5.0} = quote} =
               gateway(:post, "/internal/v1/payments/quote", hash, %{"amount_usd" => 5, "asset" => "nep141:btc.omft.near", "refund_to" => "bc1qpayer"})

      refute JSON.encode!(quote) =~ "0x"
      assert {200, %{"payments" => [_one]}} = gateway(:get, "/internal/v1/payments", hash)
      assert {400, _} = gateway(:post, "/internal/v1/payments/quote", hash, %{"amount_usd" => 0.1, "asset" => "nep141:wrap.near", "refund_to" => "payer.near"})
    end

    test "what arrived is what is credited; a refund, a failure and a partial deposit credit nothing" do
      {key, hash} = prepaid()

      {201, %{"id" => less, "deposit" => %{"address" => a1}}} = pay(hash, %{"amount_usd" => 10})
      {201, %{"id" => refunded, "deposit" => %{"address" => a2}}} = pay(hash)
      {201, %{"id" => failed, "deposit" => %{"address" => a3}}} = pay(hash)
      {201, %{"id" => partial, "deposit" => %{"address" => a4}}} = pay(hash)
      {201, %{"id" => more, "deposit" => %{"address" => a5}}} = pay(hash, %{"amount_usd" => 2})

      FakeIntents.outcome(a1, {"SUCCESS", delivered("9970000")})
      FakeIntents.outcome(a2, {"REFUNDED", %{"refundReason" => "PARTIAL_DEPOSIT"}})
      FakeIntents.outcome(a3, {"FAILED", %{}})
      FakeIntents.outcome(a4, {"INCOMPLETE_DEPOSIT", %{}})
      # Far more than was asked for is not believed beyond a small margin.
      FakeIntents.outcome(a5, {"SUCCESS", delivered("500000000")})
      :ok = Payments.poll_now()

      assert {200, %{"status" => "settled", "credited_usd" => 9.97}} = gateway(:get, "/internal/v1/payments/#{less}", hash)

      assert {200, %{"status" => "refunded", "credited_usd" => nil, "detail" => "refunded to the payer (PARTIAL_DEPOSIT)"}} =
               gateway(:get, "/internal/v1/payments/#{refunded}", hash)

      assert {200, %{"status" => "failed", "credited_usd" => nil}} = gateway(:get, "/internal/v1/payments/#{failed}", hash)

      assert {200, %{"status" => "awaiting_deposit", "provider_status" => "INCOMPLETE_DEPOSIT", "detail" => "less than" <> _}} =
               gateway(:get, "/internal/v1/payments/#{partial}", hash)

      assert {200, %{"status" => "settled", "credited_usd" => 2.1}} = gateway(:get, "/internal/v1/payments/#{more}", hash)
      assert_in_delta key(key.name).budget_usd, 12.07, 1.0e-9

      # Ended payments are not asked about again.
      before = FakeIntents.get(:calls)
      :ok = Payments.poll_now()
      assert FakeIntents.get(:calls) == before + 1
    end

    test "an answer that is not about our quote credits nothing, and the payment stays open" do
      {key, hash} = prepaid()
      {201, %{"id" => id, "deposit" => %{"address" => address}}} = pay(hash)

      for tamper <- [:recipient, :signature, :address] do
        FakeIntents.outcome(address, {"SUCCESS", delivered("5000000"), tamper})
        :ok = Payments.poll_now()
        assert {200, %{"status" => "awaiting_deposit", "credited_usd" => nil}} = gateway(:get, "/internal/v1/payments/#{id}", hash)
      end

      FakeIntents.set(:mode, :down)
      :ok = Payments.poll_now()
      assert {200, %{"status" => "awaiting_deposit"}} = gateway(:get, "/internal/v1/payments/#{id}", hash)
      assert key(key.name).budget_usd == 0.0

      # The provider back and honest: settled after all.
      FakeIntents.set(:mode, nil)
      FakeIntents.outcome(address, {"SUCCESS", delivered("5000000")})
      :ok = Payments.poll_now()
      assert key(key.name).budget_usd == 5.0
    end

    test "nothing sent by the deadline: expired, nothing credited; a deposit on its way keeps it open" do
      {key, hash} = prepaid()
      {201, %{"id" => waiting}} = pay(hash)
      {201, %{"id" => moving, "deposit" => %{"address" => address}}} = pay(hash)
      FakeIntents.outcome(address, {"KNOWN_DEPOSIT_TX", %{}})

      # Both deadlines passed twenty minutes ago.
      past = System.os_time(:second) - 1200
      :sys.replace_state(Payments, fn state -> %{state | payments: Enum.map(state.payments, &Map.put(&1, "deadline_at", past))} end)
      :ok = Payments.poll_now()

      assert {200, %{"status" => "expired", "detail" => "no deposit arrived before the deadline", "credited_usd" => nil}} =
               gateway(:get, "/internal/v1/payments/#{waiting}", hash)

      assert {200, %{"status" => "processing"}} = gateway(:get, "/internal/v1/payments/#{moving}", hash)
      assert key(key.name).budget_usd == 0.0
    end

    test "settled for a key that cannot be credited: said plainly, credited nowhere" do
      {key, hash} = prepaid()
      {201, %{"deposit" => %{"address" => address}}} = pay(hash)
      :ok = Keys.delete(key.name)
      FakeIntents.outcome(address, {"SUCCESS", delivered("5000000")})
      :ok = Payments.poll_now()

      assert [%{"status" => "settled", "credited_usd" => nil, "detail" => "the funds arrived, but the key could not be credited" <> _}] =
               Payments.all(10) |> Enum.filter(&(&1["key"] == key.name))

      wait_until(fn -> Enum.any?(Audit.recent(100), &(&1["action"] == "payment.settle" and &1["outcome"] == "uncredited" and &1["target"] == key.name)) end)
      _ = hash
    end

    test "survives a restart of its store: still open, then credited once" do
      {key, hash} = prepaid()
      {201, %{"id" => id, "deposit" => %{"address" => address}}} = pay(hash)

      :ok = Supervisor.terminate_child(OmnigateControl.Root, Payments)
      {:ok, _} = Supervisor.restart_child(OmnigateControl.Root, Payments)
      assert {200, %{"status" => "awaiting_deposit", "deposit" => %{"address" => ^address}}} = gateway(:get, "/internal/v1/payments/#{id}", hash)

      FakeIntents.outcome(address, {"SUCCESS", delivered("5000000")})
      # The store's own clock asks (every second, at `poll_interval_s` of 1).
      wait_until(fn -> key(key.name).budget_usd == 5.0 end, 300)

      :ok = Supervisor.terminate_child(OmnigateControl.Root, Payments)
      {:ok, _} = Supervisor.restart_child(OmnigateControl.Root, Payments)
      :ok = Payments.poll_now()
      assert key(key.name).budget_usd == 5.0
      assert {200, %{"status" => "settled", "credited_usd" => 5.0}} = gateway(:get, "/internal/v1/payments/#{id}", hash)
    end
  end

  describe "who may ask for what" do
    test "a payment is its key's alone" do
      {_key, hash} = prepaid()
      {_other, other_hash} = prepaid()
      {201, %{"id" => id}} = pay(hash)

      assert {404, %{"error" => %{"code" => "payment_not_found"}}} = gateway(:get, "/internal/v1/payments/#{id}", other_hash)
      assert {200, %{"payments" => []}} = gateway(:get, "/internal/v1/payments", other_hash)
      assert {404, _} = gateway(:post, "/internal/v1/payments/#{id}/tx", other_hash, %{"tx_hash" => "0xabc"})
      assert {404, _} = gateway(:get, "/internal/v1/payments/pay_nonexistent", hash)
      assert {401, _} = request(:get, "/internal/v1/payments/#{id}", [{"x-omnigate-key-sha256", hash}])
      assert {401, _} = request(:get, "/admin/payments", [])
    end

    test "only a prepaid key created through the admin API can be paid for" do
      {:ok, _open, raw} = Keys.create(%{"name" => unique("open")})
      assert {409, %{"error" => %{"code" => "not_prepaid"}}} = pay(OmnigateControl.sha256_hex(raw))
      {:ok, _monthly, raw} = Keys.create(%{"name" => unique("monthly"), "budget_usd" => 5, "budget_period" => "monthly"})
      assert {409, %{"error" => %{"code" => "not_prepaid"}}} = pay(OmnigateControl.sha256_hex(raw))
      file_key = Enum.find(ConfigStore.get().keys, &(&1.source == :file))
      assert {409, %{"error" => %{"code" => "not_prepaid", "message" => message}}} = pay(file_key.key_sha256)
      assert message =~ "config file"
      assert FakeIntents.get(:seen) == []
    end

    test "what is asked is checked before the provider hears of it" do
      {_key, hash} = prepaid()

      for {bad, word} <- [
            {%{"amount_usd" => 0.5}, "smallest"},
            {%{"amount_usd" => 20_000}, "largest"},
            {%{"amount_usd" => "5"}, "amount_usd"},
            {%{"amount_usd" => nil}, "amount_usd"},
            {%{"asset" => "not an asset"}, "asset"},
            {%{"asset" => 5}, "asset"},
            {%{"refund_to" => ""}, "refund_to"},
            {%{"refund_to" => "two words"}, "refund_to"},
            {%{"refund_to" => nil}, "refund_to"}
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request", "message" => message}}} = pay(hash, bad)
        assert message =~ word
      end

      assert FakeIntents.get(:seen) == []

      # The provider's own refusal reaches the payer in its words; nothing is stored.
      assert {400, %{"error" => %{"code" => "payment_quote_refused", "message" => message}}} = pay(hash, %{"refund_to" => "nowhere"})
      assert message =~ "refundTo is not valid"
      assert {200, %{"payments" => []}} = gateway(:get, "/internal/v1/payments", hash)

      # A quote that fails its checks is never shown: no address to send funds to.
      FakeIntents.set(:mode, :bad_signature)
      assert {502, %{"error" => %{"code" => "payment_provider_error"}} = body} = pay(hash)
      refute JSON.encode!(body) =~ "0x"
      assert {200, %{"payments" => []}} = gateway(:get, "/internal/v1/payments", hash)
    end

    test "a key may have only so many payments waiting, and ask only so often" do
      {_key, hash} = prepaid()
      for _ <- 1..5, do: assert({201, _} = pay(hash))
      assert {429, %{"error" => %{"code" => "too_many_open_payments"}}} = pay(hash)

      # Another key, asking faster than six times a minute.
      {_key, hash} = prepaid()
      :sys.replace_state(Payments, &%{&1 | payments: []})
      results = for _ <- 1..8, do: pay(hash) |> elem(0)
      :sys.replace_state(Payments, &%{&1 | payments: []})
      assert Enum.count(results, &(&1 == 201)) <= 6
      assert 429 in results
    end

    test "the deposit's transaction hash is passed on, for an open payment only" do
      {_key, hash} = prepaid()
      {201, %{"id" => id, "deposit" => %{"address" => address}}} = pay(hash)
      assert {400, _} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => "two words"})
      assert {400, _} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{})
      assert {200, %{"id" => ^id}} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => "0xabc123"})
      assert {:submitted, %{"depositAddress" => ^address, "txHash" => "0xabc123"}} = hd(FakeIntents.get(:seen))

      FakeIntents.outcome(address, {"FAILED", %{}})
      :ok = Payments.poll_now()
      assert {409, %{"error" => %{"code" => "payment_closed"}}} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => "0xabc123"})
    end

    test "without a \"payments\" section there is nothing: every endpoint is a 404", %{original: original} do
      {_key, hash} = prepaid()
      :persistent_term.put({ConfigStore, :config}, Map.put(original, :payments, nil))

      for {method, path, body} <- [
            {:get, "/internal/v1/payments/assets", nil},
            {:post, "/internal/v1/payments", %{"amount_usd" => 5, "asset" => "nep141:wrap.near", "refund_to" => "payer.near"}},
            {:post, "/internal/v1/payments/quote", %{"amount_usd" => 5, "asset" => "nep141:wrap.near", "refund_to" => "payer.near"}},
            {:get, "/internal/v1/payments", nil},
            {:get, "/internal/v1/payments/pay_x", nil},
            {:post, "/internal/v1/payments/pay_x/tx", %{"tx_hash" => "0x1"}}
          ] do
        assert {404, _} = gateway(method, path, hash, body)
      end

      assert {200, %{"configured" => false, "payments" => []}} = admin(:get, "/admin/payments")
      assert FakeIntents.get(:calls) == 0
    end
  end
end
