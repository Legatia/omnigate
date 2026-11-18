defmodule OmnigateControl.PaymentsSolanaTest do
  # Payments in USDC on Solana, straight to the operator's wallet: the
  # settings, the quote (a reference, a Solana Pay link, an amount of its
  # own), and how a transfer is recognized on the chain, by its reference or
  # by its exact amount. The chain is played by `FakeRpc`, in process;
  # nothing here opens a connection.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{ConfigStore, Keys, Payments, Router}
  alias OmnigateControl.Payments.{NearIntents, Solana}

  @moduletag :capture_log
  @usdc "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  # (Any 32 bytes in Base58 are an address.)
  @wallet "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  @token_account "7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi"
  @other_mint "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"

  defmodule FakeRpc do
    @moduledoc false
    # A Solana JSON-RPC endpoint as the adapter sees it: the transactions
    # that mention an address, a transaction, a wallet's token accounts.

    def start(accounts) do
      {:ok, _} = Agent.start_link(fn -> %{signatures: %{}, txs: %{}, accounts: accounts, mode: nil, calls: []} end, name: __MODULE__)
      :ok
    end

    def set(field, value), do: Agent.update(__MODULE__, &Map.put(&1, field, value))
    def calls(method), do: Agent.get(__MODULE__, fn s -> Enum.count(s.calls, &(&1 == method)) end)

    @doc "Put a transaction on the chain: mentioned by `addresses`, moving `units` of `mint` to `owner`."
    def land(signature, addresses, owner, mint, units, opts \\ []) do
      entry = %{
        "signature" => signature,
        "err" => opts[:err],
        "blockTime" => opts[:at] || System.os_time(:second),
        "confirmationStatus" => opts[:status] || "finalized"
      }

      tx = %{
        "blockTime" => entry["blockTime"],
        "transaction" => %{"message" => %{"accountKeys" => Enum.map(addresses, &%{"pubkey" => &1, "signer" => false})}},
        "meta" => %{
          "err" => opts[:err],
          "preTokenBalances" => [balance(owner, mint, 1_000_000), balance("SomeoneElse", mint, 50_000_000)],
          "postTokenBalances" => [balance(owner, mint, 1_000_000 + units), balance("SomeoneElse", mint, 50_000_000 - units)]
        }
      }

      Agent.update(__MODULE__, fn s ->
        signatures = Enum.reduce(addresses, s.signatures, fn address, acc -> Map.update(acc, address, [entry], &[entry | &1]) end)
        %{s | signatures: signatures, txs: Map.put(s.txs, signature, tx)}
      end)
    end

    @doc "Make every transaction final."
    def finalize do
      Agent.update(__MODULE__, fn s ->
        %{s | signatures: Map.new(s.signatures, fn {a, list} -> {a, Enum.map(list, &Map.put(&1, "confirmationStatus", "finalized"))} end)}
      end)
    end

    defp balance(owner, mint, units), do: %{"owner" => owner, "mint" => mint, "uiTokenAmount" => %{"amount" => Integer.to_string(units), "decimals" => 6}}

    def request(:post, _url, _headers, body, _opts) do
      %{"method" => method, "params" => params} = JSON.decode!(body)
      state = Agent.get_and_update(__MODULE__, fn s -> {s, %{s | calls: [method | s.calls]}} end)

      case {state.mode, method, params} do
        {:down, _, _} ->
          {:error, :econnrefused}

        {:busy, _, _} ->
          {:ok, %{status: 429, headers: %{}, body: "Too many requests"}}

        {:rpc_error, _, _} ->
          json(%{"error" => %{"code" => -32_005, "message" => "Node is behind"}})

        {_, "getSignaturesForAddress", [address, %{"limit" => limit}]} ->
          json(%{"result" => Enum.take(Map.get(state.signatures, address, []), limit)})

        {_, "getTransaction", [signature, %{"commitment" => "finalized"}]} ->
          # Asked for final transactions only: one that is not final yet is not there.
          entry = state.signatures |> Map.values() |> List.flatten() |> Enum.find(&(&1["signature"] == signature))
          json(%{"result" => if(entry == nil or entry["confirmationStatus"] == "finalized", do: state.txs[signature])})

        {_, "getTransaction", [signature | _]} ->
          json(%{"result" => state.txs[signature]})

        {_, "getTokenAccountsByOwner", [_owner, %{"mint" => _}, _]} ->
          json(%{"result" => %{"value" => Enum.map(state.accounts, &%{"pubkey" => &1})}})

        _ ->
          json(%{"error" => %{"code" => -32_601, "message" => "Method not found"}})
      end
    end

    defp json(body), do: {:ok, %{status: 200, headers: %{}, body: JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => 1}, body))}}
  end

  setup do
    original = :persistent_term.get({ConfigStore, :config})
    :ok = FakeRpc.start([@token_account])

    config =
      %{"provider" => "solana", "recipient" => @wallet, "rpc_url" => "http://solana.test", "poll_interval_s" => 1}
      |> Payments.normalize!()
      |> Map.put(:http, &FakeRpc.request/5)

    :persistent_term.put({ConfigStore, :config}, Map.put(original, :payments, config))
    :persistent_term.erase({Payments, :assets})
    :ets.delete_all_objects(Solana.cache())

    on_exit(fn ->
      for k <- Keys.managed(), do: Keys.delete(k.name)
      :persistent_term.put({ConfigStore, :config}, original)
      :persistent_term.erase({Payments, :assets})
      :sys.replace_state(Payments, &%{&1 | payments: []})
      :ets.delete_all_objects(Solana.cache())
    end)

    {:ok, config: config}
  end

  defp prepaid do
    name = "sol-payer-#{System.unique_integer([:positive])}"
    {:ok, key, raw} = Keys.create(%{"name" => name, "budget_usd" => 0})
    {key, OmnigateControl.sha256_hex(raw)}
  end

  defp key(name), do: Enum.find(Keys.managed(), &(&1.name == name))

  defp gateway(method, path, hash, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn =
      conn
      |> put_req_header("x-omnigate-internal", OmnigateControl.internal_token())
      |> put_req_header("x-omnigate-key-sha256", hash)
      |> Router.call(Router.init([]))

    {conn.status, JSON.decode!(conn.resp_body)}
  end

  defp admin(method, path, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = conn |> put_req_header("authorization", "Bearer test-admin-token-0123456789") |> Router.call(Router.init([]))
    {conn.status, JSON.decode!(conn.resp_body)}
  end

  # The payment as if nothing had arrived before its deadline.
  defp expire(id) do
    :sys.replace_state(Payments, fn state ->
      %{state | payments: Enum.map(state.payments, &if(&1["id"] == id, do: &1 |> Map.put("status", "expired") |> Map.delete("next_poll_at"), else: &1))}
    end)
  end

  defp pay(hash, attrs \\ %{}), do: gateway(:post, "/internal/v1/payments", hash, Map.merge(%{"amount_usd" => 5, "asset" => "solana:" <> @usdc}, attrs))
  defp seen(id, hash), do: gateway(:get, "/internal/v1/payments/#{id}", hash) |> elem(1)
  defp signature(n), do: NearIntents.base58_encode(:crypto.hash(:sha512, "tx #{n}"))

  describe "settings" do
    test "the wallet is required and must be an address; the rest has defaults" do
      config = Payments.normalize!(%{"provider" => "solana", "recipient" => @wallet})

      assert %{
               provider: "solana",
               recipient: @wallet,
               mint: @usdc,
               decimals: 6,
               symbol: "USDC",
               commitment: "finalized",
               rpc_url: "https://api.mainnet-beta.solana.com"
             } =
               config

      assert_raise ArgumentError, ~r/Solana wallet address/, fn -> Payments.normalize!(%{"provider" => "solana", "recipient" => "operator.near"}) end
      assert_raise ArgumentError, ~r/recipient is required/, fn -> Payments.normalize!(%{"provider" => "solana"}) end
      assert_raise ArgumentError, ~r/commitment/, fn -> Payments.normalize!(%{"provider" => "solana", "recipient" => @wallet, "commitment" => "processed"}) end
      assert_raise ArgumentError, ~r/mint/, fn -> Payments.normalize!(%{"provider" => "solana", "recipient" => @wallet, "mint" => "usdc"}) end
      assert_raise ArgumentError, ~r/rpc_url/, fn -> Payments.normalize!(%{"provider" => "solana", "recipient" => @wallet, "rpc_url" => "ftp://x"}) end
      # The other provider's fields are not this one's.
      assert_raise ArgumentError, ~r/unknown field\(s\) slippage_bps/, fn ->
        Payments.normalize!(%{"provider" => "solana", "recipient" => @wallet, "slippage_bps" => 50})
      end

      assert_raise ArgumentError, ~r/"near_intents" or "solana"/, fn -> Payments.normalize!(%{"provider" => "bank", "recipient" => @wallet}) end
    end

    test "amounts are written without noise" do
      assert Solana.formatted(5_000_000, 6) == "5.00"
      assert Solana.formatted(5_004_217, 6) == "5.004217"
      assert Solana.formatted(5_100_000, 6) == "5.10"
      assert Solana.formatted(123, 6) == "0.000123"
    end
  end

  describe "a quote" do
    test "names the wallet, a reference of its own, a Solana Pay link and an amount no open payment has", %{config: config} do
      deadline = System.os_time(:second) + 600
      request = %{amount_usd: 5.0, asset: "solana:" <> @usdc, refund_to: nil, deadline: deadline, dry: false}

      assert {:ok, quoted} = Solana.quote(config, request)
      assert %{"deposit_address" => @wallet, "deposit_memo" => nil, "deposit_reference" => reference, "pay_url" => url, "amount_in" => units} = quoted
      assert Solana.address?(reference)
      assert {n, ""} = Integer.parse(units)
      assert n > 5_000_000 and n < 5_010_000
      assert quoted["amount_in_formatted"] == Solana.formatted(n, 6)

      assert %URI{scheme: "solana", path: @wallet, query: query} = URI.parse(url)
      assert URI.decode_query(query) == %{"amount" => quoted["amount_in_formatted"], "spl-token" => @usdc, "reference" => reference}
      # The QR code of the top-up page holds 180 bytes.
      assert byte_size(url) <= 180

      # Another quote: another reference; and never an amount that is taken.
      taken = for i <- 1..9_998, do: Integer.to_string(5_000_000 + i)
      assert {:ok, %{"amount_in" => "5009999", "deposit_reference" => other}} = Solana.quote(config, Map.put(request, :taken, taken))
      assert other != reference

      all = for i <- 1..9_999, do: Integer.to_string(5_000_000 + i)
      assert {:error, 503, "payment_provider_unavailable", _} = Solana.quote(config, Map.put(request, :taken, all))

      # A dry quote: the plain amount, no address, nothing to pay yet.
      assert {:ok, %{"deposit_address" => nil, "amount_in" => "5000000", "amount_in_formatted" => "5.00"} = dry} = Solana.quote(config, %{request | dry: true})
      refute Map.has_key?(dry, "pay_url")

      assert {:error, 400, "payment_quote_refused", message} = Solana.quote(config, %{request | asset: "nep141:wrap.near"})
      assert message =~ "solana:" <> @usdc
      assert FakeRpc.calls("getTransaction") == 0
    end
  end

  describe "a payment" do
    test "found by its reference: processing until final, then credited once with what arrived" do
      {key, hash} = prepaid()

      assert {200, %{"assets" => [%{"asset" => "solana:" <> @usdc, "symbol" => "USDC", "chain" => "solana", "decimals" => 6}]}} =
               gateway(:get, "/internal/v1/payments/assets", hash)

      # No refund address: this provider gives nothing back by itself.
      assert {201, payment} = pay(hash)

      assert %{
               "id" => id,
               "status" => "awaiting_deposit",
               "provider" => "solana",
               "refund_to" => nil,
               "deposit" => %{
                 "address" => @wallet,
                 "memo" => nil,
                 "reference" => reference,
                 "url" => "solana:" <> _,
                 "symbol" => "USDC",
                 "chain" => "solana",
                 "amount_units" => units
               }
             } = payment

      units = String.to_integer(units)

      :ok = Payments.poll_now()
      assert %{"status" => "awaiting_deposit"} = seen(id, hash)

      # A transaction that failed, and one that mentions the reference but
      # pays another mint: neither is a payment.
      FakeRpc.land(signature(1), [reference], @wallet, @usdc, units, err: %{"InstructionError" => [0, "Custom"]})
      FakeRpc.land(signature(2), [reference], @wallet, @other_mint, units)
      :ok = Payments.poll_now()
      assert %{"status" => "awaiting_deposit", "credited_usd" => nil} = seen(id, hash)

      # The transfer, confirmed but not final: seen, not credited.
      FakeRpc.land(signature(3), [reference, @token_account], @wallet, @usdc, units, status: "confirmed")
      :ok = Payments.poll_now()
      sig = signature(3)
      assert %{"status" => "processing", "credited_usd" => nil, "tx" => [^sig], "provider_status" => "confirmed"} = seen(id, hash)
      assert key(key.name).budget_usd == 0.0

      FakeRpc.finalize()
      :ok = Payments.poll_now()
      credited = units / 1_000_000
      assert %{"status" => "settled", "credited_usd" => ^credited, "tx" => [^sig], "detail" => nil} = seen(id, hash)
      assert_in_delta key(key.name).budget_usd, credited, 1.0e-9

      # Credited under the payment's reference, as credit from "solana".
      assert [%{"reference" => "solana:" <> ^reference, "source" => "solana", "amount_usd" => ^credited}] =
               Enum.filter(Keys.topups(50), &(&1["key"] == key.name))

      # Asked again, nothing more is credited.
      :ok = Payments.poll_now()
      assert_in_delta key(key.name).budget_usd, credited, 1.0e-9
    end

    test "found by its exact amount: a plain transfer made after the payment started" do
      {key, hash} = prepaid()
      {other_key, other_hash} = prepaid()

      # A transfer of some amount that was there before: not this payment's.
      FakeRpc.land(signature(10), [@token_account], @wallet, @usdc, 5_000_000, at: System.os_time(:second) - 3_600)

      assert {201, %{"id" => id, "deposit" => %{"amount_units" => units}}} = pay(hash)
      assert {201, %{"id" => other_id, "deposit" => %{"amount_units" => other_units}}} = pay(other_hash)
      # Two open payments of the same number of dollars wait for different amounts.
      assert units != other_units
      units = String.to_integer(units)

      # A transfer of the asked-for dollars without the fraction, and one of
      # the right amount that is older than the payment: not recognized.
      FakeRpc.land(signature(11), [@token_account], @wallet, @usdc, 5_000_000)
      FakeRpc.land(signature(12), [@token_account], @wallet, @usdc, units, at: System.os_time(:second) - 600)
      :ok = Payments.poll_now()
      assert %{"status" => "awaiting_deposit"} = seen(id, hash)
      assert %{"status" => "awaiting_deposit"} = seen(other_id, other_hash)

      FakeRpc.land(signature(13), [@token_account], @wallet, @usdc, units)
      # (The list of the wallet's transactions is kept for a few seconds.)
      :ets.delete_all_objects(Solana.cache())
      :ok = Payments.poll_now()
      credited = units / 1_000_000
      sig = signature(13)
      assert %{"status" => "settled", "credited_usd" => ^credited, "tx" => [^sig]} = seen(id, hash)
      # The other payment, of the other amount, is still waiting.
      assert %{"status" => "awaiting_deposit"} = seen(other_id, other_hash)
      assert_in_delta key(key.name).budget_usd, credited, 1.0e-9
      assert key(other_key.name).budget_usd == 0.0
    end

    test "a transaction that was read is not read again; the wallet's accounts are asked for once" do
      {_key, hash} = prepaid()
      assert {201, %{"id" => id}} = pay(hash)
      FakeRpc.land(signature(20), [@token_account], @wallet, @usdc, 1_234_567)

      for _ <- 1..3 do
        :ets.match_delete(Solana.cache(), {{:solana_signatures, :_, :_}, :_, :_})
        :ok = Payments.poll_now()
      end

      assert %{"status" => "awaiting_deposit"} = seen(id, hash)
      assert FakeRpc.calls("getTransaction") == 1
      assert FakeRpc.calls("getTokenAccountsByOwner") == 1
    end

    test "a chain that cannot be asked credits nothing and the payment stays open" do
      {key, hash} = prepaid()
      assert {201, %{"id" => id, "deposit" => %{"reference" => reference, "amount_units" => units}}} = pay(hash)
      FakeRpc.land(signature(30), [reference], @wallet, @usdc, String.to_integer(units))

      for mode <- [:down, :busy, :rpc_error] do
        FakeRpc.set(:mode, mode)
        :ok = Payments.poll_now()
        assert %{"status" => "awaiting_deposit", "credited_usd" => nil} = seen(id, hash)
      end

      assert key(key.name).budget_usd == 0.0
      FakeRpc.set(:mode, nil)
      :ok = Payments.poll_now()
      assert %{"status" => "settled"} = seen(id, hash)
    end

    test "a wallet that never held the token: nothing to look through, still found by reference" do
      FakeRpc.set(:accounts, [])
      {_key, hash} = prepaid()
      assert {201, %{"id" => id, "deposit" => %{"reference" => reference, "amount_units" => units}}} = pay(hash)
      :ok = Payments.poll_now()
      assert %{"status" => "awaiting_deposit"} = seen(id, hash)

      FakeRpc.land(signature(40), [reference], @wallet, @usdc, String.to_integer(units))
      :ok = Payments.poll_now()
      assert %{"status" => "settled"} = seen(id, hash)
    end

    test "less than asked, sent with the reference, is credited as what arrived; far more is not believed beyond the amount" do
      {key, hash} = prepaid()
      assert {201, %{"id" => id, "deposit" => %{"reference" => reference}}} = pay(hash)
      FakeRpc.land(signature(50), [reference], @wallet, @usdc, 2_000_000)
      :ok = Payments.poll_now()
      assert %{"status" => "settled", "credited_usd" => 2.0} = seen(id, hash)
      assert key(key.name).budget_usd == 2.0

      {big, big_hash} = prepaid()
      assert {201, %{"id" => big_id, "deposit" => %{"reference" => big_reference}}} = pay(big_hash)
      FakeRpc.land(signature(51), [big_reference], @wallet, @usdc, 900_000_000)
      :ok = Payments.poll_now()
      assert %{"status" => "settled", "credited_usd" => 5.25} = seen(big_id, big_hash)
      assert key(big.name).budget_usd == 5.25
    end
  end

  describe "a transfer that was not recognized, named by its signature" do
    test "the payer names a transaction that carries the reference of an expired payment: credited at once, and once" do
      {key, hash} = prepaid()
      assert {201, %{"id" => id, "deposit" => %{"reference" => reference}}} = pay(hash)
      expire(id)

      # Not on the chain yet; then there, and not final.
      assert {409, %{"error" => %{"code" => "tx_not_final"}}} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => signature(60)})
      FakeRpc.land(signature(60), [reference, @token_account], @wallet, @usdc, 5_000_000, status: "confirmed")
      assert {409, %{"error" => %{"code" => "tx_not_final"}}} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => signature(60)})
      assert key(key.name).budget_usd == 0.0

      FakeRpc.finalize()
      sig = signature(60)

      assert {200, %{"status" => "settled", "credited_usd" => 5.0, "tx" => [^sig], "claimed_tx" => nil}} =
               gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => sig})

      assert key(key.name).budget_usd == 5.0
      assert [%{"reference" => "solana:tx:" <> ^sig, "source" => "solana", "amount_usd" => 5.0}] = Enum.filter(Keys.topups(50), &(&1["key"] == key.name))

      # Named again, for this payment or for another: nothing more.
      assert {409, %{"error" => %{"code" => "payment_closed"}}} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => sig})
      assert {201, %{"id" => second}} = pay(hash)
      expire(second)

      assert {200, %{"status" => "expired", "claimed_tx" => %{"signature" => ^sig}}} =
               gateway(:post, "/internal/v1/payments/#{second}/tx", hash, %{"tx_hash" => sig})

      assert {409, %{"error" => %{"code" => "tx_already_credited"}}} = admin(:post, "/admin/payments/credit", %{"payment" => second, "tx" => sig})
      assert key(key.name).budget_usd == 5.0
    end

    test "a transfer nothing ties to the payer is only noted; the operator confirms it, and it is credited once" do
      {key, hash} = prepaid()
      {thief, thief_hash} = prepaid()
      assert {201, %{"id" => id}} = pay(hash)
      assert {201, %{"id" => thief_id}} = pay(thief_hash)

      # Sent by hand: a round amount, no reference.
      sig = signature(70)
      FakeRpc.land(sig, [@token_account], @wallet, @usdc, 5_000_000)
      :ok = Payments.poll_now()
      assert %{"status" => "awaiting_deposit"} = seen(id, hash)

      # Anyone can name it (the wallet is public): nobody is credited by that.
      for {pid, h} <- [{thief_id, thief_hash}, {id, hash}] do
        assert {200, %{"status" => "awaiting_deposit", "credited_usd" => nil, "claimed_tx" => %{"signature" => ^sig, "amount_usd" => 5.0}}} =
                 gateway(:post, "/internal/v1/payments/#{pid}/tx", h, %{"tx_hash" => sig})
      end

      assert key(key.name).budget_usd == 0.0 and key(thief.name).budget_usd == 0.0

      # The operator sees who named what, and confirms one of them.
      assert {200, %{"credit_by_tx" => true, "provider" => "solana", "payments" => listed}} = admin(:get, "/admin/payments")
      assert Enum.count(listed, &(&1["claimed_tx"]["signature"] == sig)) == 2

      assert {200, %{"id" => ^id, "status" => "settled", "credited_usd" => 5.0, "key" => name, "tx" => [^sig], "claimed_tx" => nil, "detail" => detail}} =
               admin(:post, "/admin/payments/credit", %{"payment" => id, "tx" => sig})

      assert name == key.name and detail =~ "operator"
      # The admin API shows the reference it was credited under.
      assert {200, %{"payments" => after_credit}} = admin(:get, "/admin/payments")
      assert %{"reference" => "solana:tx:" <> ^sig} = Enum.find(after_credit, &(&1["id"] == id))
      assert key(key.name).budget_usd == 5.0

      # The same transaction for the other payment, or for a key: refused.
      assert {409, %{"error" => %{"code" => "tx_already_credited"}}} = admin(:post, "/admin/payments/credit", %{"payment" => thief_id, "tx" => sig})
      assert {409, %{"error" => %{"code" => "tx_already_credited"}}} = admin(:post, "/admin/payments/credit", %{"key" => thief.name, "tx" => sig})
      assert {409, %{"error" => %{"code" => "payment_closed"}}} = admin(:post, "/admin/payments/credit", %{"payment" => id, "tx" => sig})
      assert key(thief.name).budget_usd == 0.0
      # A later poll does not credit the settled payment again.
      :ok = Payments.poll_now()
      assert key(key.name).budget_usd == 5.0
    end

    test "the operator credits a transaction to a key without a payment; what is refused" do
      {key, _hash} = prepaid()
      sig = signature(80)
      FakeRpc.land(sig, [@token_account], @wallet, @usdc, 12_500_000)

      assert {200, %{"status" => "settled", "credited_usd" => 12.5, "key" => name, "tx" => [^sig], "provider" => "solana", "deposit" => %{"amount" => "12.50"}}} =
               admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => sig})

      assert name == key.name
      assert key(key.name).budget_usd == 12.5
      assert {409, %{"error" => %{"code" => "tx_already_credited"}}} = admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => sig})

      # A transaction that failed, one that pays another mint, one that is
      # too old, one that is not a signature, a key that is not there.
      FakeRpc.land(signature(81), [@token_account], @wallet, @usdc, 1_000_000, err: %{"InstructionError" => [0, "Custom"]})
      FakeRpc.land(signature(82), [@token_account], @wallet, @other_mint, 1_000_000)
      FakeRpc.land(signature(83), [@token_account], @wallet, @usdc, 1_000_000, at: System.os_time(:second) - 61 * 86_400)
      FakeRpc.land(signature(84), [@token_account], @wallet, @usdc, 1_000_000)

      assert {400, %{"error" => %{"code" => "tx_not_a_payment"}}} = admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => signature(81)})
      assert {400, %{"error" => %{"code" => "tx_not_a_payment"}}} = admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => signature(82)})
      assert {400, %{"error" => %{"code" => "tx_too_old"}}} = admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => signature(83)})
      assert {400, %{"error" => %{"code" => "invalid_request"}}} = admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => "not-a-signature"})
      assert {400, %{"error" => %{"code" => "invalid_request"}}} = admin(:post, "/admin/payments/credit", %{"tx" => signature(84)})
      assert {404, %{"error" => %{"code" => "payment_not_found"}}} = admin(:post, "/admin/payments/credit", %{"payment" => "pay_nope", "tx" => signature(84)})
      assert {404, %{"error" => %{"code" => "key_not_found"}}} = admin(:post, "/admin/payments/credit", %{"key" => "nobody", "tx" => signature(84)})
      # (Refused for a key that is not there, it can still be credited to one that is.)
      assert {200, %{"credited_usd" => 1.0}} = admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => signature(84)})
      assert key(key.name).budget_usd == 13.5

      FakeRpc.set(:mode, :down)
      FakeRpc.land(signature(85), [@token_account], @wallet, @usdc, 1_000_000)

      assert {503, %{"error" => %{"code" => "payment_provider_unavailable"}}} =
               admin(:post, "/admin/payments/credit", %{"key" => key.name, "tx" => signature(85)})

      assert key(key.name).budget_usd == 13.5
    end

    test "a transaction a payment was credited for by itself cannot be credited again from its signature" do
      {key, hash} = prepaid()
      {other, _} = prepaid()
      assert {201, %{"id" => id, "deposit" => %{"reference" => reference, "amount_units" => units}}} = pay(hash)
      sig = signature(90)
      FakeRpc.land(sig, [reference], @wallet, @usdc, String.to_integer(units))
      :ok = Payments.poll_now()
      assert %{"status" => "settled"} = seen(id, hash)
      before = key(key.name).budget_usd

      assert {409, %{"error" => %{"code" => "tx_already_credited"}}} = admin(:post, "/admin/payments/credit", %{"key" => other.name, "tx" => sig})
      assert {409, %{"error" => %{"code" => "payment_closed"}}} = gateway(:post, "/internal/v1/payments/#{id}/tx", hash, %{"tx_hash" => sig})
      assert key(key.name).budget_usd == before and key(other.name).budget_usd == 0.0
    end
  end
end
