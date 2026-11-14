defmodule OmnigateControl.Payments.Solana do
  @moduledoc """
  Payments in a dollar stablecoin on Solana, straight to the operator's own
  wallet: no third party between the payer and the operator. The settings
  name the wallet (`recipient`) and the gateway watches the chain through a
  Solana JSON-RPC endpoint until the transfer is there.

  Every payment goes to the same wallet, so a payment is told apart from the
  others in two ways, and either is enough:

    * **A reference.** Each payment gets a fresh 32-byte reference, written
      like an address. A Solana Pay link (`pay_url`, also drawn as the QR
      code of the top-up page) makes the payer's wallet add it to the
      transfer as a read-only account, and the gateway finds the transfer
      by asking the chain for transactions that mention it. This is the
      Solana Pay transfer request (https://docs.solanapay.com/spec, read
      14 November 2026).
    * **The exact amount.** The amount to send is the amount asked for plus
      a fraction of a cent that no other open payment has: 10 dollars
      becomes, say, 10.004217. A plain transfer of exactly that amount to
      the wallet, made after the payment was started, is that payment.

  ## What is checked

  For a transaction found either way the gateway reads the transaction
  itself and takes the amount from its token balances: how much more of the
  mint the recipient owns after it than before. A transaction that failed
  counts for nothing. By default only a **finalized** transaction is
  credited; until then the payment is `processing`.

  What is **not** checked independently: the RPC endpoint's word. The
  gateway does not verify block signatures; it believes what the configured
  endpoint says over TLS. Point `rpc_url` at an endpoint you trust.

  ## What this provider does not do

  It never refunds: the funds are in the operator's wallet the moment they
  are paid, and giving them back is the operator's act, by hand. A transfer
  that arrives after the payment expired, or with an amount that matches no
  open payment and without a reference, is not credited either; the
  operator can add the credit by hand (`POST /admin/keys/{name}/topup`).

  ## Settings (inside `"payments"`)

    * `recipient` — the operator's wallet address (the owner, not a token
      account).
    * `rpc_url` — the JSON-RPC endpoint (default: Solana's public mainnet
      endpoint, which is rate limited; use your own for real traffic).
    * `mint` — the token's mint (default: USDC). It should be a dollar
      stablecoin: what arrives is credited one to one.
    * `decimals` — the mint's decimals (default 6), `symbol` its name
      (default `USDC`).
    * `commitment` — `finalized` (default) or `confirmed`: when a transfer
      is believed.
  """
  @behaviour OmnigateControl.Payments.Provider

  alias OmnigateControl.Payments.NearIntents

  @rpc_url "https://api.mainnet-beta.solana.com"
  @usdc "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  @known ~w(rpc_url mint decimals symbol commitment)
  @timeout 20_000
  # The cache every status question shares (owned by `Payments`).
  @cache :omnigate_payments_cache
  @max_cached 5_000
  @accounts_ttl_ms 600_000
  @signatures_ttl_ms 4_000
  # How many of the wallet's latest transactions are looked through for an
  # exact amount.
  @recent 50

  @doc "The fields of `\"payments\"` this provider reads."
  def fields, do: @known

  @doc "The name of the cache table `Payments` creates for this provider."
  def cache, do: @cache

  @doc "This provider gives nothing back by itself, so a payment needs no refund address."
  def refund_address?, do: false

  @doc "The operator's wallet, validated: a 32-byte address in Base58. Raises `ArgumentError`."
  def recipient!(address) do
    if address?(address),
      do: address,
      else: raise(ArgumentError, "payments.recipient must be a Solana wallet address (32 bytes in Base58), got #{inspect(address)}")
  end

  @doc "True for 32 bytes in Base58."
  def address?(text) when is_binary(text) and byte_size(text) in 32..44 do
    match?({:ok, <<_::binary-size(32)>>}, NearIntents.base58(text))
  end

  def address?(_), do: false

  @impl true
  def normalize!(raw) do
    %{
      rpc_url:
        case raw["rpc_url"] do
          nil -> @rpc_url
          "http" <> _ = url -> String.trim_trailing(url, "/")
          other -> raise ArgumentError, "payments.rpc_url must be an http(s) URL, got #{inspect(other)}"
        end,
      mint:
        case raw["mint"] do
          nil -> @usdc
          mint -> if address?(mint), do: mint, else: raise(ArgumentError, "payments.mint must be a token mint address, got #{inspect(mint)}")
        end,
      decimals:
        case raw["decimals"] do
          nil -> 6
          n when is_integer(n) and n >= 6 and n <= 12 -> n
          other -> raise ArgumentError, "payments.decimals must be a whole number from 6 to 12, got #{inspect(other)}"
        end,
      symbol:
        case raw["symbol"] do
          nil -> "USDC"
          s when is_binary(s) -> if s =~ ~r/\A[A-Za-z0-9.]{1,12}\z/, do: s, else: raise(ArgumentError, "payments.symbol must be 1-12 letters or digits")
          other -> raise ArgumentError, "payments.symbol must be text, got #{inspect(other)}"
        end,
      commitment:
        case raw["commitment"] do
          nil -> "finalized"
          c when c in ["finalized", "confirmed"] -> c
          other -> raise ArgumentError, "payments.commitment must be \"finalized\" or \"confirmed\", got #{inspect(other)}"
        end
    }
  end

  @doc "The id of the one asset this provider takes."
  def asset_id(config), do: "solana:" <> config.mint

  # ---- Assets --------------------------------------------------------------------

  @impl true
  def assets(config) do
    {:ok, [%{"asset" => asset_id(config), "symbol" => config.symbol, "chain" => "solana", "decimals" => config.decimals, "price_usd" => 1.0}]}
  end

  # ---- Quotes --------------------------------------------------------------------

  @impl true
  def quote(config, %{amount_usd: amount_usd, asset: asset, deadline: deadline} = request) do
    scale = Integer.pow(10, config.decimals)
    base = (amount_usd * scale) |> Float.round() |> trunc()

    cond do
      asset != asset_id(config) ->
        {:error, 400, "payment_quote_refused", "this gateway takes #{config.symbol} on Solana only: asset #{asset_id(config)}"}

      Map.get(request, :dry, false) ->
        {:ok, quoted(config, base, deadline)}

      true ->
        # A fraction of a cent no other open payment has: it tells a plain
        # transfer of this payment from one of another.
        step = div(scale, 1_000_000)
        taken = MapSet.new(Map.get(request, :taken, []))

        free? = &(not MapSet.member?(taken, Integer.to_string(&1)))
        random = Stream.repeatedly(fn -> base + :rand.uniform(9_999) * step end) |> Enum.take(16)

        # (A few at random; with most of them taken, the first that is free.)
        case Enum.find(random, free?) || Enum.find(Stream.map(1..9_999, &(base + &1 * step)), free?) do
          nil ->
            {:error, 503, "payment_provider_unavailable", "too many payments of this amount are waiting; try again shortly or ask for another amount"}

          units ->
            reference = NearIntents.base58_encode(:crypto.strong_rand_bytes(32))

            url =
              "solana:" <>
                config.recipient <>
                "?" <> URI.encode_query([{"amount", formatted(units, config.decimals)}, {"spl-token", config.mint}, {"reference", reference}])

            {:ok,
             quoted(config, units, deadline)
             |> Map.merge(%{"deposit_address" => config.recipient, "deposit_reference" => reference, "pay_url" => url, "proof" => %{"mint" => config.mint}})}
        end
    end
  end

  defp quoted(config, units, deadline) do
    text = formatted(units, config.decimals)

    %{
      "deposit_address" => nil,
      "deposit_memo" => nil,
      "amount_in" => Integer.to_string(units),
      "amount_in_formatted" => text,
      "min_amount_in" => Integer.to_string(units),
      "amount_in_usd" => text,
      "deadline" => deadline |> DateTime.from_unix!() |> DateTime.to_iso8601(),
      "time_estimate_s" => if(config.commitment == "finalized", do: 20, else: 5),
      "proof" => nil
    }
  end

  @doc "`units` of the smallest unit as a decimal number, without trailing zeros beyond the cents."
  def formatted(units, decimals) do
    scale = Integer.pow(10, decimals)
    whole = div(units, scale)
    fraction = units |> rem(scale) |> Integer.to_string() |> String.pad_leading(decimals, "0") |> String.trim_trailing("0") |> String.pad_trailing(2, "0")
    "#{whole}.#{fraction}"
  end

  # ---- Status --------------------------------------------------------------------

  @impl true
  def status(config, payment) do
    # (A payment keeps the wallet and the mint it was quoted for.)
    config = %{config | recipient: payment["deposit_address"], mint: get_in(payment, ["proof", "mint"]) || config.mint}

    with {:ok, nil} <- by_reference(config, payment),
         {:ok, nil} <- by_amount(config, payment) do
      {:ok, %{state: :awaiting_deposit, delivered_usd: nil, detail: nil, raw: nil, tx: []}}
    else
      {:ok, %{} = outcome} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  # A transaction that mentions the payment's reference and pays the wallet.
  defp by_reference(config, %{"deposit_reference" => reference}) when is_binary(reference) do
    with {:ok, entries} <- signatures(config, reference, 10, 0) do
      first_paying(config, entries, fn units -> units > 0 end)
    end
  end

  defp by_reference(_config, _payment), do: {:ok, nil}

  # A transfer of exactly the payment's amount to one of the wallet's token
  # accounts, made after the payment was started.
  defp by_amount(config, payment) do
    with {units, ""} <- Integer.parse(payment["amount_in"] || ""),
         {:ok, since, _} <- DateTime.from_iso8601(payment["created_at"] || ""),
         {:ok, accounts} <- token_accounts(config) do
      since = DateTime.to_unix(since)

      Enum.reduce_while(accounts, {:ok, nil}, fn account, _ ->
        with {:ok, entries} <- signatures(config, account, @recent, @signatures_ttl_ms),
             recent = Enum.filter(entries, &(is_integer(&1["blockTime"]) and &1["blockTime"] >= since)),
             {:ok, nil} <- first_paying(config, recent, &(&1 == units)) do
          {:cont, {:ok, nil}}
        else
          other -> {:halt, other}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:ok, nil}
    end
  end

  # The oldest of `entries` (newest first, as the chain lists them) that
  # succeeded and whose amount passes `wanted?`, as an outcome; nil if none.
  defp first_paying(config, entries, wanted?) do
    entries
    |> Enum.filter(&(is_nil(&1["err"]) and is_binary(&1["signature"])))
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, nil}, fn entry, _ ->
      case transfer(config, entry) do
        {:ok, units} ->
          if wanted?.(units), do: {:halt, {:ok, outcome(config, entry, units)}}, else: {:cont, {:ok, nil}}

        # (Listed but not readable yet: a moment later it is.)
        {:error, :not_found} ->
          {:cont, {:ok, nil}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp outcome(config, entry, units) do
    base = %{delivered_usd: nil, detail: nil, raw: entry["confirmationStatus"], tx: [entry["signature"]]}

    if believed?(config, entry) do
      base |> Map.put(:state, :settled) |> Map.put(:delivered_usd, units / Integer.pow(10, config.decimals))
    else
      base |> Map.put(:state, :processing) |> Map.put(:detail, "the transfer is on the chain and not final yet")
    end
  end

  defp believed?(config, entry) do
    entry["confirmationStatus"] == "finalized" or (config.commitment == "confirmed" and entry["confirmationStatus"] == "confirmed")
  end

  # How much more of the mint the wallet owns after the transaction than
  # before, in the smallest unit; 0 for one that failed.
  defp transfer(config, %{"signature" => signature} = entry) do
    key = {:solana_tx, config.rpc_url, config.recipient, config.mint, signature}

    case cached(key, :infinity) do
      {:ok, units} ->
        {:ok, units}

      :miss ->
        params = [signature, %{"encoding" => "jsonParsed", "commitment" => "confirmed", "maxSupportedTransactionVersion" => 1}]

        case rpc(config, "getTransaction", params) do
          {:ok, %{"meta" => %{} = meta}} ->
            units = if is_nil(meta["err"]), do: owned(meta["postTokenBalances"], config) - owned(meta["preTokenBalances"], config), else: 0
            # (Only what can no longer change is remembered.)
            if entry["confirmationStatus"] == "finalized", do: remember(key, units)
            {:ok, units}

          {:ok, nil} ->
            {:error, :not_found}

          {:ok, other} ->
            {:error, {:unreadable, inspect(other) |> String.slice(0, 80)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp owned(balances, config) when is_list(balances) do
    for %{"owner" => owner, "mint" => mint, "uiTokenAmount" => %{"amount" => amount}} <- balances,
        owner == config.recipient and mint == config.mint and is_binary(amount),
        {units, ""} <- [Integer.parse(amount)],
        reduce: 0 do
      sum -> sum + units
    end
  end

  defp owned(_, _config), do: 0

  # The wallet's token accounts for the mint.
  defp token_accounts(config) do
    key = {:solana_accounts, config.rpc_url, config.recipient, config.mint}

    case cached(key, @accounts_ttl_ms) do
      {:ok, accounts} ->
        {:ok, accounts}

      :miss ->
        case rpc(config, "getTokenAccountsByOwner", [config.recipient, %{"mint" => config.mint}, %{"encoding" => "jsonParsed", "commitment" => "confirmed"}]) do
          {:ok, %{"value" => list}} when is_list(list) ->
            accounts = for %{"pubkey" => account} <- list, address?(account), do: account
            # (A wallet that never held the token gets its account with the first payment.)
            if accounts != [], do: remember(key, accounts)
            {:ok, Enum.take(accounts, 4)}

          {:ok, other} ->
            {:error, {:unreadable, inspect(other) |> String.slice(0, 80)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # The latest transactions that mention `address`, newest first.
  defp signatures(config, address, limit, ttl_ms) do
    key = {:solana_signatures, config.rpc_url, address}

    case if(ttl_ms > 0, do: cached(key, ttl_ms), else: :miss) do
      {:ok, entries} ->
        {:ok, entries}

      :miss ->
        case rpc(config, "getSignaturesForAddress", [address, %{"limit" => limit, "commitment" => "confirmed"}]) do
          {:ok, list} when is_list(list) ->
            entries = Enum.filter(list, &is_map/1)
            if ttl_ms > 0, do: remember(key, entries)
            {:ok, entries}

          {:ok, other} ->
            {:error, {:unreadable, inspect(other) |> String.slice(0, 80)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ---- Deposit transaction hint -------------------------------------------------------

  @impl true
  # Nothing to pass on: the chain is asked again at once (`Payments.submit_tx/3`).
  def submit_tx(_config, _payment, _tx_hash), do: :ok

  # ---- The cache ------------------------------------------------------------------------

  defp cached(key, ttl_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@cache) != :undefined && :ets.lookup(@cache, key) do
      [{^key, at, value}] when ttl_ms == :infinity or now - at < ttl_ms -> {:ok, value}
      _ -> :miss
    end
  end

  defp remember(key, value) do
    if :ets.whereis(@cache) != :undefined do
      if :ets.info(@cache, :size) >= @max_cached, do: :ets.delete_all_objects(@cache)
      :ets.insert(@cache, {key, System.monotonic_time(:millisecond), value})
    end

    :ok
  end

  # ---- JSON-RPC ---------------------------------------------------------------------------

  # `{:ok, result}` or `{:error, reason}`.
  defp rpc(config, method, params) do
    http = Map.get(config, :http) || (&OmnigateControl.Http.request/5)
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    case http.(:post, config.rpc_url, [{"accept", "application/json"}], body, timeout: @timeout, max_body: 4 * 1024 * 1024) do
      {:ok, %{status: 200, body: raw}} ->
        case JSON.decode(raw) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> {:error, {:rpc, method, clip(message)}}
          _ -> {:error, {:rpc, method, "an answer that is not JSON-RPC"}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clip(text), do: text |> String.replace(~r/[^\x20-\x7E]/, " ") |> String.slice(0, 160)
end
