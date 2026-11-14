defmodule OmnigateControl.Payments.NearIntents do
  @moduledoc """
  Payments through NEAR Intents, by way of its 1Click API
  (https://docs.near-intents.org, read 11 November 2026).

  A payer may pay with any asset 1Click lists, on any chain it supports.
  For each payment the gateway asks 1Click for an `EXACT_OUTPUT` quote: "so
  that exactly N of the settle asset reaches the operator's account, how much
  of this asset must be sent, and where?" 1Click answers with a deposit
  address on the payer's chain. The payer sends the funds there; NEAR Intents
  swaps them and delivers the settle asset (native USDC on NEAR unless set
  otherwise) to the operator's NEAR account. The gateway only reads: it asks
  for the quote and then for the status until the payment has an end.

  ## What is checked

    * A quote carries 1Click's Ed25519 signature over its fields. It is
      verified against 1Click's manager key (pinned below, taken from
      1Click's own SDK) before the deposit address is shown to anyone, and
      the quote must repeat what was asked: the recipient, the settle asset,
      the amount, the payer's refund address.
    * A status answer repeats the quote it is about; it must be the quote
      that was stored (same signature, same deposit address, same
      recipient), or it is not believed.

  One oddity of the real service, found on 11 November 2026: some assets
  are listed twice (Bitcoin as `nep141:btc.omft.near` and as
  `1cs_v1:btc:native:coin`), and a quote asked for under the first id is
  signed as if it had been asked for under the second, while the answer
  repeats the first. So a signature is accepted if it verifies with the
  asset id that was asked for **or** with another id the provider's own list
  gives the same coin on the same chain (`:aliases` in the request; worked
  out by `Payments` from that list). Everything else in the signature is
  exactly what was asked: recipient, amount, refund address, deposit address.

  What is **not** checked independently: that the settle asset arrived. A
  status of `SUCCESS` is 1Click's word, received over TLS from the configured
  host. The status itself is not signed. See `docs/payments.md`.

  ## Settings (inside `"payments"`)

    * `settle_asset` — the asset delivered to the operator (default: native
      USDC on NEAR). It should be a dollar stablecoin: what arrives is
      credited one to one.
    * `settle_decimals` — its decimals (default 6).
    * `slippage_bps` — tolerance on the amount the payer sends (default 100,
      that is 1%; what the swap does not need is refunded to the payer).
    * `jwt_env` — environment variable holding a 1Click partner token.
      Without one 1Click adds 0.25% to every quote.
    * `base_url`, `public_key` — where 1Click is and the key it signs with;
      only ever changed to point at a test double.

  Not run against real funds: every call here has been made against the real
  service as a dry quote only (`tools/near_intents_live.py`), and against a
  mock for everything after a deposit.
  """
  @behaviour OmnigateControl.Payments.Provider

  @base_url "https://1click.chaindefuser.com"
  # ONE_CLICK_MANAGER_PUB_KEY in @defuse-protocol/one-click-sdk-typescript
  # (src/quote-signature.ts), Base58; a live dry quote verified against it on
  # 11 November 2026.
  @manager_key "reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc"
  @usdc_on_near "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
  @known ~w(settle_asset settle_decimals slippage_bps jwt_env base_url public_key)
  @timeout 30_000

  @doc "The fields of `\"payments\"` this provider reads."
  def fields, do: @known

  @doc "A failed swap is refunded on the paying chain, so a payment needs a refund address."
  def refund_address?, do: true

  @doc "The operator's NEAR account, validated. Raises `ArgumentError`."
  def recipient!(account) do
    if account =~ ~r/\A[a-z0-9][a-z0-9._\-]{1,63}\z/,
      do: account,
      else: raise(ArgumentError, "payments.recipient is not an account name: #{inspect(account)}")
  end

  @impl true
  def normalize!(raw) do
    %{
      settle_asset:
        case raw["settle_asset"] do
          nil -> @usdc_on_near
          id when is_binary(id) -> if asset_id?(id), do: id, else: raise(ArgumentError, "payments.settle_asset is not an asset id: #{inspect(id)}")
          other -> raise ArgumentError, "payments.settle_asset must be an asset id, got #{inspect(other)}"
        end,
      settle_decimals:
        case raw["settle_decimals"] do
          nil -> 6
          n when is_integer(n) and n >= 0 and n <= 30 -> n
          other -> raise ArgumentError, "payments.settle_decimals must be a whole number from 0 to 30, got #{inspect(other)}"
        end,
      slippage_bps:
        case raw["slippage_bps"] do
          nil -> 100
          n when is_integer(n) and n >= 0 and n <= 1_000 -> n
          other -> raise ArgumentError, "payments.slippage_bps must be a whole number of basis points from 0 to 1000, got #{inspect(other)}"
        end,
      jwt_env:
        case raw["jwt_env"] do
          nil -> nil
          name when is_binary(name) and name != "" -> name
          other -> raise ArgumentError, "payments.jwt_env must be the name of an environment variable, got #{inspect(other)}"
        end,
      base_url:
        case raw["base_url"] do
          nil -> @base_url
          "http" <> _ = url -> String.trim_trailing(url, "/")
          other -> raise ArgumentError, "payments.base_url must be an http(s) URL, got #{inspect(other)}"
        end,
      public_key:
        case raw["public_key"] do
          nil ->
            @manager_key

          key when is_binary(key) ->
            case base58(unprefixed(key)) do
              {:ok, <<_::binary-size(32)>>} -> unprefixed(key)
              _ -> raise ArgumentError, "payments.public_key must be an Ed25519 public key in Base58"
            end

          other ->
            raise ArgumentError, "payments.public_key must be an Ed25519 public key in Base58, got #{inspect(other)}"
        end
    }
  end

  @doc "True for something shaped like a 1Click asset id."
  def asset_id?(id), do: is_binary(id) and id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9:._\-]{0,199}\z/

  # ---- Assets --------------------------------------------------------------------

  @impl true
  def assets(config) do
    case call(config, :get, "/v0/tokens", nil) do
      {:ok, 200, list} when is_list(list) ->
        {:ok,
         for %{"assetId" => id, "symbol" => symbol, "blockchain" => chain, "decimals" => decimals} = token <- list,
             is_binary(id) and is_binary(symbol) and is_binary(chain) and is_integer(decimals) do
           %{"asset" => id, "symbol" => symbol, "chain" => chain, "decimals" => decimals, "price_usd" => if(is_number(token["price"]), do: token["price"])}
         end}

      other ->
        refusal(other)
    end
  end

  # ---- Quotes --------------------------------------------------------------------

  @impl true
  def quote(config, %{amount_usd: amount_usd, asset: asset, refund_to: refund_to, deadline: deadline} = request) do
    dry = Map.get(request, :dry, false)
    amount = units(amount_usd, config.settle_decimals)

    body = %{
      "dry" => dry,
      "swapType" => "EXACT_OUTPUT",
      "slippageTolerance" => config.slippage_bps,
      "originAsset" => asset,
      "depositType" => "ORIGIN_CHAIN",
      "destinationAsset" => config.settle_asset,
      "amount" => amount,
      "recipient" => config.recipient,
      "recipientType" => "DESTINATION_CHAIN",
      "refundTo" => refund_to,
      "refundType" => "ORIGIN_CHAIN",
      "deadline" => deadline |> DateTime.from_unix!() |> DateTime.to_iso8601()
    }

    with {:ok, status, %{"quote" => %{} = quote, "quoteRequest" => %{} = echoed} = answer} when status in [200, 201] <- call(config, :post, "/v0/quote", body),
         {:ok, signed_as} <- signed_as(answer, config, [asset | Map.get(request, :aliases, [])]),
         :ok <- same_request(echoed, body),
         :ok <- usable(quote, amount, dry) do
      {:ok,
       %{
         "deposit_address" => quote["depositAddress"],
         "deposit_memo" => if(is_binary(quote["depositMemo"]) and quote["depositMemo"] != "", do: quote["depositMemo"]),
         "amount_in" => quote["amountIn"],
         "amount_in_formatted" => quote["amountInFormatted"],
         "min_amount_in" => quote["minAmountIn"],
         "amount_in_usd" => quote["amountInUsd"],
         "amount_out" => quote["amountOut"],
         "deadline" => quote["deadline"] || echoed["deadline"],
         "time_estimate_s" => if(is_number(quote["timeEstimate"]), do: quote["timeEstimate"]),
         # (`origin_asset`: the id the signature names the asset by, see the module's notes.)
         "proof" => %{
           "signature" => answer["signature"],
           "timestamp" => answer["timestamp"],
           "correlation_id" => answer["correlationId"],
           "origin_asset" => signed_as
         }
       }}
    else
      {:error, :bad_signature} ->
        {:error, 502, "payment_provider_error", "the payment provider's quote is not signed by its key; it was not used"}

      {:error, :mismatch, what} ->
        {:error, 502, "payment_provider_error", "the payment provider's quote does not repeat what was asked (#{what}); it was not used"}

      other ->
        refusal(other)
    end
  end

  # What the provider says it was asked must be what it was asked.
  defp same_request(echoed, body) do
    case Enum.find(~w(dry swapType originAsset depositType destinationAsset amount recipient recipientType refundTo refundType), &(echoed[&1] != body[&1])) do
      nil -> :ok
      field -> {:error, :mismatch, field}
    end
  end

  defp usable(quote, amount, dry) do
    cond do
      quote["amountOut"] != amount -> {:error, :mismatch, "amountOut"}
      not digits?(quote["amountIn"]) or not digits?(quote["minAmountIn"]) -> {:error, :mismatch, "amountIn"}
      not dry and not (is_binary(quote["depositAddress"]) and quote["depositAddress"] =~ ~r/\A[!-~]{1,180}\z/) -> {:error, :mismatch, "depositAddress"}
      true -> :ok
    end
  end

  defp digits?(text), do: is_binary(text) and text =~ ~r/\A[0-9]{1,60}\z/

  # ---- Status --------------------------------------------------------------------

  @impl true
  def status(config, payment) do
    query =
      URI.encode_query(
        [{"depositAddress", payment["deposit_address"]}] ++ if(payment["deposit_memo"], do: [{"depositMemo", payment["deposit_memo"]}], else: [])
      )

    case call(config, :get, "/v0/status?" <> query, nil) do
      {:ok, 200, %{"status" => raw, "quoteResponse" => %{"quote" => %{} = quote, "quoteRequest" => %{} = echoed} = answer} = body} when is_binary(raw) ->
        cond do
          # The answer must be about the quote this payment was made on.
          quote["depositAddress"] != payment["deposit_address"] -> {:error, {:mismatch, "depositAddress"}}
          answer["signature"] != get_in(payment, ["proof", "signature"]) -> {:error, {:mismatch, "signature"}}
          echoed["recipient"] != payment["recipient"] -> {:error, {:mismatch, "recipient"}}
          echoed["destinationAsset"] != payment["settle_asset"] -> {:error, {:mismatch, "destinationAsset"}}
          signed(answer, config, get_in(payment, ["proof", "origin_asset"])) != :ok -> {:error, :bad_signature}
          true -> {:ok, outcome(raw, body["swapDetails"] || %{}, config)}
        end

      {:ok, status, body} ->
        {:error, {:http, status, message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp outcome(raw, details, config) do
    tx = for %{"hash" => hash} <- List.wrap(details["destinationChainTxHashes"]) ++ List.wrap(details["originChainTxHashes"]), is_binary(hash), do: hash
    base = %{delivered_usd: nil, detail: nil, raw: raw, tx: Enum.take(tx, 8)}

    case raw do
      "PENDING_DEPOSIT" ->
        %{base | detail: nil} |> Map.put(:state, :awaiting_deposit)

      "INCOMPLETE_DEPOSIT" ->
        base
        |> Map.put(:state, :awaiting_deposit)
        |> Map.put(:detail, "less than the required amount has arrived; send the rest before the deadline, or it is refunded")

      status when status in ["KNOWN_DEPOSIT_TX", "PROCESSING"] ->
        Map.put(base, :state, :processing)

      "SUCCESS" ->
        case details["amountOut"] do
          amount when is_binary(amount) ->
            if digits?(amount) do
              base |> Map.put(:state, :settled) |> Map.put(:delivered_usd, String.to_integer(amount) / Integer.pow(10, config.settle_decimals))
            else
              base |> Map.put(:state, :processing) |> Map.put(:detail, "the provider reports success without an amount")
            end

          _ ->
            base |> Map.put(:state, :processing) |> Map.put(:detail, "the provider reports success without an amount")
        end

      "REFUNDED" ->
        reason = if is_binary(details["refundReason"]), do: " (#{clip(details["refundReason"], 60)})", else: ""
        base |> Map.put(:state, :refunded) |> Map.put(:detail, "refunded to the payer" <> reason)

      "FAILED" ->
        base |> Map.put(:state, :failed) |> Map.put(:detail, "the provider could not complete the swap")

      other ->
        base |> Map.put(:state, :processing) |> Map.put(:detail, "provider status #{clip(other, 40)}")
    end
  end

  # ---- Deposit transaction hint -------------------------------------------------------

  @impl true
  def submit_tx(config, payment, tx_hash) do
    body = %{"depositAddress" => payment["deposit_address"], "txHash" => tx_hash}
    body = if payment["deposit_memo"], do: Map.put(body, "memo", payment["deposit_memo"]), else: body

    case call(config, :post, "/v0/deposit/submit", body) do
      {:ok, status, _} when status in 200..299 -> :ok
      other -> refusal(other)
    end
  end

  # ---- The quote signature ----------------------------------------------------------

  @doc """
  The text 1Click signs for a quote answer: the Base58 of the SHA-256 of
  the signed fields as JSON with sorted keys (what its SDK's `quoteHash`
  computes). `nil` when the answer has not the shape of one.
  """
  def signed_text(%{"quote" => %{} = quote, "quoteRequest" => %{} = request, "timestamp" => timestamp}) when is_binary(timestamp) do
    dry = request["dry"] == true

    always =
      Map.take(request, ~w(dry swapType slippageTolerance originAsset depositType destinationAsset amount refundTo refundType recipient recipientType deadline))

    # Fields the SDK signs only when they are set ("truthy" in JavaScript).
    optional =
      request
      |> Map.take(~w(quoteWaitingTimeMs referral virtualChainRecipient virtualChainRefundRecipient customRecipientMsg))
      |> Map.filter(fn {_, v} -> truthy?(v) end)

    amounts = Map.take(quote, ~w(amountIn amountInFormatted amountInUsd minAmountIn amountOut amountOutFormatted amountOutUsd minAmountOut))

    execution =
      if dry,
        do: %{},
        else:
          quote
          |> Map.take(~w(depositAddress depositMemo deadline timeWhenInactive timeEstimate refundFee withdrawFee))
          |> Map.filter(fn {_, v} -> truthy?(v) end)

    fields =
      always |> Map.merge(optional) |> Map.merge(amounts) |> Map.merge(execution) |> Map.put("timestamp", timestamp) |> Map.reject(fn {_, v} -> is_nil(v) end)

    json = "{" <> Enum.map_join(Enum.sort(Map.keys(fields)), ",", fn key -> JSON.encode!(key) <> ":" <> JSON.encode!(fields[key]) end) <> "}"
    base58_encode(:crypto.hash(:sha256, json))
  end

  def signed_text(_), do: nil

  defp truthy?(v), do: v not in [nil, false, 0, "", 0.0]

  # The first of `ids` under which the answer's signature verifies.
  defp signed_as(answer, config, ids) do
    case Enum.find(Enum.uniq(ids), &(signed(answer, config, &1) == :ok)) do
      nil -> {:error, :bad_signature}
      id -> {:ok, id}
    end
  end

  @doc """
  `:ok` when the quote answer carries a valid signature of the provider's
  key, else `{:error, :bad_signature}`. With `origin_asset`, the signature is
  checked as naming the paying asset by that id instead of the one the
  answer repeats (see the module's notes on assets listed twice).
  """
  def signed(answer, config, origin_asset \\ nil) do
    answer = if is_binary(origin_asset) and is_map(answer["quoteRequest"]), do: put_in(answer, ["quoteRequest", "originAsset"], origin_asset), else: answer

    with text when is_binary(text) <- signed_text(answer),
         "ed25519:" <> encoded <- answer["signature"],
         {:ok, <<signature::binary-size(64)>>} <- base58(encoded),
         {:ok, <<public::binary-size(32)>>} <- base58(config.public_key),
         true <- :crypto.verify(:eddsa, :none, text, signature, [public, :ed25519]) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :bad_signature}
  end

  # ---- Base58 (the Bitcoin alphabet) --------------------------------------------------

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc false
  def base58(text) when is_binary(text) and byte_size(text) <= 200 do
    digits = for <<c <- text>>, do: Enum.find_index(@alphabet, &(&1 == c))

    if text == "" or Enum.any?(digits, &is_nil/1) do
      :error
    else
      number = Enum.reduce(digits, 0, fn digit, acc -> acc * 58 + digit end)
      zeros = digits |> Enum.take_while(&(&1 == 0)) |> length()
      {:ok, :binary.copy(<<0>>, zeros) <> if(number == 0, do: <<>>, else: :binary.encode_unsigned(number))}
    end
  end

  def base58(_), do: :error

  @doc false
  def base58_encode(bytes) when is_binary(bytes) do
    zeros = for(<<b <- bytes>>, do: b) |> Enum.take_while(&(&1 == 0)) |> length()
    String.duplicate("1", zeros) <> encode_number(:binary.decode_unsigned(bytes), "")
  end

  defp encode_number(0, acc), do: acc
  defp encode_number(n, acc), do: encode_number(div(n, 58), <<Enum.at(@alphabet, rem(n, 58))>> <> acc)

  defp unprefixed("ed25519:" <> key), do: key
  defp unprefixed(key), do: key

  # ---- HTTP ---------------------------------------------------------------------------

  # `{:ok, status, decoded_json_or_text}` or `{:error, reason}`.
  defp call(config, method, path, body) do
    headers =
      [{"accept", "application/json"}] ++
        case config.jwt_env && System.get_env(config.jwt_env) do
          token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
          _ -> []
        end

    http = Map.get(config, :http) || (&OmnigateControl.Http.request/5)

    case http.(method, config.base_url <> path, headers, body && JSON.encode!(body), timeout: @timeout, max_body: 2 * 1024 * 1024) do
      {:ok, %{status: status, body: raw}} ->
        case JSON.decode(raw) do
          {:ok, decoded} -> {:ok, status, decoded}
          _ -> {:ok, status, raw}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What the provider refused, in the gateway's words. Its own message is
  # passed on for a 400 (it says what is wrong with the request: an address
  # that is not one, an amount below what a bridge takes).
  defp refusal({:ok, 400, body}), do: {:error, 400, "payment_quote_refused", "the payment provider refused the request: " <> message(body)}
  defp refusal({:ok, 401, _}), do: {:error, 502, "payment_provider_error", "the payment provider refused the gateway's credentials"}
  defp refusal({:ok, 429, _}), do: {:error, 503, "payment_provider_unavailable", "the payment provider is rate limiting; try again shortly"}
  defp refusal({:ok, status, _}) when is_integer(status), do: {:error, 502, "payment_provider_error", "the payment provider answered HTTP #{status}"}
  defp refusal({:error, _reason}), do: {:error, 503, "payment_provider_unavailable", "the payment provider could not be reached"}
  defp refusal(_), do: {:error, 502, "payment_provider_error", "the payment provider sent an answer the gateway could not read"}

  defp message(%{"message" => message}) when is_binary(message), do: clip(message, 200)
  defp message(_), do: "no reason given"

  defp clip(text, max), do: text |> String.replace(~r/[^\x20-\x7E]/, " ") |> String.slice(0, max)

  # `amount_usd` in the settle asset's smallest unit, as the integer string the API takes.
  defp units(amount_usd, decimals), do: (amount_usd * Integer.pow(10, decimals)) |> Float.round() |> trunc() |> Integer.to_string()
end
