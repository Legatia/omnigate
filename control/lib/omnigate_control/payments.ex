defmodule OmnigateControl.Payments do
  @moduledoc """
  Taking payments for prepaid credit. Opt-in: without a `"payments"` section
  in the config there are no payment endpoints and this process does nothing.

  The holder of a prepaid gateway key asks for a payment of some amount in
  US dollars, to be paid with an asset they name. A payment provider
  (`OmnigateControl.Payments.Provider`; the one there is, `near_intents`,
  is `OmnigateControl.Payments.NearIntents`) answers with a deposit address
  and the exact amount to send. The payer sends it; the provider delivers
  the settle asset to the operator's own account; this process asks the
  provider what became of the payment until it has an end, and when it has
  settled credits the key through `Keys.topup/2`, under a reference derived
  from the deposit address, so that it is credited exactly once however
  often it is seen settled.

  **The gateway holds no keys, signs nothing and moves no funds.** It reads
  a quote and a status. Funds go from the payer to the provider's deposit
  address and from there to the operator's account.

  ## Settings (`"payments"`)

    * `provider` — required; `"near_intents"`.
    * `recipient` — required; the operator's account at the provider (a NEAR
      account for `near_intents`).
    * `min_usd`, `max_usd` — bounds on one payment (default 1 and 10,000).
    * `quote_ttl_s` — how long a payer has to send the deposit (default 1800).
    * `poll_interval_s` — how often an open payment is asked about
      (default 15; later polls are spaced further apart).
    * plus the provider's own fields.

  ## A payment's states

      awaiting_deposit → processing → settled       (credited)
                                    → refunded       (the provider gave the funds back)
                                    → failed
      awaiting_deposit → expired                     (nothing arrived by the deadline)

  A settled payment whose key cannot be credited (it was deleted, or is no
  longer prepaid) stays `settled` with `credited_usd` null and says why:
  the funds reached the operator, and what to do about it is theirs.

  ## Storage

  `OMNIGATE_PAYMENTS` (default `data/payments.json`), rewritten atomically on
  every change, newest first: at most #{5_000} payments; ones that ended more
  than 90 days ago are dropped.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{Audit, ConfigStore, Credits, Keys, RateLimit}

  @max_payments 5_000
  @keep_ended_s 90 * 86_400
  @max_open_per_key 5
  @quotes_per_minute 6
  # After the deadline, how long a deposit that was on its way may still show up.
  @grace_s 900
  @assets_ttl_ms 300_000
  @open ~w(awaiting_deposit processing)
  @common ~w(provider recipient min_usd max_usd quote_ttl_s poll_interval_s)

  # ---- Settings ------------------------------------------------------------------

  @doc "The module of a provider by its name in the config, or nil."
  def provider("near_intents"), do: OmnigateControl.Payments.NearIntents
  def provider(_), do: nil

  # The module behind a normalized config (whose provider was checked then).
  defp module!(config) do
    case provider(config.provider) do
      nil -> raise ArgumentError, "no payment provider named #{inspect(config.provider)}"
      module -> module
    end
  end

  @doc "The `\"payments\"` section of a config, validated: nil when absent. Raises `ArgumentError`."
  def normalize!(nil), do: nil

  def normalize!(%{} = raw) do
    module = provider(raw["provider"]) || raise ArgumentError, "payments.provider must be \"near_intents\", got #{inspect(raw["provider"])}"

    case Map.keys(raw) -- (@common ++ module.fields()) do
      [] -> :ok
      unknown -> raise ArgumentError, "payments: unknown field(s) #{Enum.join(Enum.sort(unknown), ", ")}"
    end

    recipient =
      case raw["recipient"] do
        r when is_binary(r) ->
          if r =~ ~r/\A[a-z0-9][a-z0-9._\-]{1,63}\z/, do: r, else: raise(ArgumentError, "payments.recipient is not an account name: #{inspect(r)}")

        other ->
          raise ArgumentError, "payments.recipient is required: the account that receives payments, got #{inspect(other)}"
      end

    min_usd = number!(raw["min_usd"], 1.0, 0.01, 1.0e9, "min_usd")
    max_usd = number!(raw["max_usd"], 10_000.0, 0.01, 1.0e9, "max_usd")
    if min_usd > max_usd, do: raise(ArgumentError, "payments.min_usd is above payments.max_usd")

    Map.merge(module.normalize!(raw), %{
      provider: raw["provider"],
      recipient: recipient,
      min_usd: min_usd,
      max_usd: max_usd,
      quote_ttl_s: integer!(raw["quote_ttl_s"], 1_800, 60, 86_400, "quote_ttl_s"),
      poll_interval_s: integer!(raw["poll_interval_s"], 15, 1, 3_600, "poll_interval_s")
    })
  end

  def normalize!(other), do: raise(ArgumentError, "payments must be an object, got #{inspect(other)}")

  defp number!(nil, default, _min, _max, _name), do: default
  defp number!(n, _default, min, max, _name) when is_number(n) and n >= min and n <= max, do: n * 1.0
  defp number!(other, _default, min, max, name), do: raise(ArgumentError, "payments.#{name} must be a number from #{min} to #{max}, got #{inspect(other)}")

  defp integer!(nil, default, _min, _max, _name), do: default
  defp integer!(n, _default, min, max, _name) when is_integer(n) and n >= min and n <= max, do: n

  defp integer!(other, _default, min, max, name),
    do: raise(ArgumentError, "payments.#{name} must be a whole number from #{min} to #{max}, got #{inspect(other)}")

  @doc "The settings in force, or nil when payments are off."
  def config do
    case :persistent_term.get({ConfigStore, :config}, nil) do
      %{payments: %{} = config} -> config
      _ -> nil
    end
  end

  @doc "True when the config has a `\"payments\"` section."
  def configured?, do: config() != nil

  # ---- What a key holder may do ------------------------------------------------------

  @doc """
  The assets a payer may pay with, optionally only those of one `chain` or
  with one `symbol`. Asked of the provider at most every few minutes.
  """
  def assets(filters \\ %{}) do
    with %{} = config <- config() || off(),
         {:ok, assets} <- cached_assets(config) do
      chain = filters["chain"]
      symbol = filters["symbol"] && String.upcase(filters["symbol"])

      {:ok,
       Enum.filter(assets, fn a ->
         (is_nil(chain) or a["chain"] == chain) and (is_nil(symbol) or String.upcase(a["symbol"]) == symbol)
       end)}
    end
  end

  defp cached_assets(config) do
    now = System.monotonic_time(:millisecond)
    # (Kept per provider address, so that a config change takes effect at once.)
    source = {config.provider, Map.get(config, :base_url)}

    case :persistent_term.get({__MODULE__, :assets}, nil) do
      {at, ^source, assets} when now - at < @assets_ttl_ms ->
        {:ok, assets}

      _ ->
        with {:ok, assets} <- module!(config).assets(config) do
          :persistent_term.put({__MODULE__, :assets}, {now, source, assets})
          {:ok, assets}
        end
    end
  end

  @doc """
  Start a payment of `"amount_usd"` for `key`, to be paid with `"asset"` and
  refunded to `"refund_to"` should it fail. Returns `{:ok, payment}` with the
  deposit instructions, or `{:error, status, code, message}`.
  """
  def create(key, attrs) when is_map(attrs) do
    with %{} = config <- config() || off(),
         :ok <- prepaid(key),
         {:ok, amount} <- amount(attrs["amount_usd"], config),
         {:ok, asset} <- asset(attrs["asset"]),
         {:ok, refund_to} <- refund_to(attrs["refund_to"]),
         :ok <- room(key),
         :ok <- rate(key),
         deadline = System.os_time(:second) + config.quote_ttl_s,
         request = %{amount_usd: amount, asset: asset, refund_to: refund_to, deadline: deadline, dry: false, aliases: aliases(asset, config)},
         {:ok, quoted} <- module!(config).quote(config, request) do
      described = describe(asset, config)

      payment =
        Map.merge(quoted, %{
          "id" => "pay_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
          "key" => key.name,
          "provider" => config.provider,
          "recipient" => config.recipient,
          "settle_asset" => Map.get(config, :settle_asset),
          "amount_usd" => amount,
          "asset" => asset,
          "asset_symbol" => described["symbol"],
          "asset_chain" => described["chain"],
          "refund_to" => refund_to,
          "status" => "awaiting_deposit",
          "provider_status" => nil,
          "credited_usd" => nil,
          "detail" => nil,
          "tx" => [],
          "created_at" => now_iso(),
          "updated_at" => now_iso(),
          "polls" => 0,
          "next_poll_at" => System.os_time(:second) + config.poll_interval_s
        })
        |> Map.put("deadline_at", deadline_unix(quoted["deadline"], deadline))

      GenServer.call(__MODULE__, {:insert, payment})
    end
  end

  @doc """
  What a payment of `"amount_usd"` with `"asset"` would take, without
  starting one: the amount to send and how long the swap takes. Nothing is
  created at the provider and there is no deposit address.
  """
  def quote_only(key, attrs) when is_map(attrs) do
    with %{} = config <- config() || off(),
         :ok <- prepaid(key),
         {:ok, amount} <- amount(attrs["amount_usd"], config),
         {:ok, asset} <- asset(attrs["asset"]),
         {:ok, refund_to} <- refund_to(attrs["refund_to"]),
         :ok <- rate(key),
         request = %{
           amount_usd: amount,
           asset: asset,
           refund_to: refund_to,
           deadline: System.os_time(:second) + config.quote_ttl_s,
           dry: true,
           aliases: aliases(asset, config)
         },
         {:ok, quoted} <- module!(config).quote(config, request) do
      described = describe(asset, config)

      {:ok,
       %{
         amount_usd: amount,
         asset: asset,
         symbol: described["symbol"],
         chain: described["chain"],
         amount: quoted["amount_in_formatted"],
         amount_units: quoted["amount_in"],
         min_amount_units: quoted["min_amount_in"],
         deposit_usd: quoted["amount_in_usd"],
         time_estimate_s: quoted["time_estimate_s"],
         provider: config.provider
       }}
    end
  end

  # Other ids the provider's list gives the same coin on the same chain
  # ("BTC" and "BTC(OMNI)", both Bitcoin with 8 decimals): a provider may sign
  # a quote under either.
  defp aliases(asset, config) do
    with {:ok, assets} <- cached_assets(config),
         %{"chain" => chain, "decimals" => decimals, "symbol" => symbol} <- Enum.find(assets, &(&1["asset"] == asset)) do
      for other <- assets,
          other["asset"] != asset,
          other["chain"] == chain,
          other["decimals"] == decimals,
          coin(other["symbol"]) == coin(symbol),
          do: other["asset"]
    else
      _ -> []
    end
  end

  defp coin(symbol), do: symbol |> String.replace(~r/\(.*\)/, "") |> String.trim() |> String.upcase()

  defp describe(asset, config) do
    case cached_assets(config) do
      {:ok, assets} -> Enum.find(assets, %{}, &(&1["asset"] == asset))
      _ -> %{}
    end
  end

  defp deadline_unix(iso, fallback) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.to_unix(at)
      _ -> fallback
    end
  end

  defp deadline_unix(_, fallback), do: fallback

  @doc "The payment `id` if it is one of `key`'s, or nil."
  def own(key, id) do
    case GenServer.call(__MODULE__, {:get, id}) do
      %{"key" => name} = payment when name == key.name -> payment
      _ -> nil
    end
  end

  @doc "`key`'s payments, newest first, at most `limit`."
  def list(key, limit \\ 50), do: GenServer.call(__MODULE__, {:list, key.name, limit})

  @doc "Every payment, newest first, at most `limit` (the admin API)."
  def all(limit \\ 100), do: GenServer.call(__MODULE__, {:list, nil, limit})

  @doc "Pass the hash of the transaction that carries a payment's deposit on to the provider. Optional; it only speeds things up."
  def submit_tx(key, id, tx_hash) do
    with %{} = config <- config() || off(),
         %{} = payment <- own(key, id) || {:error, 404, "payment_not_found", "no such payment"},
         true <- (is_binary(tx_hash) and tx_hash =~ ~r/\A[!-~]{1,200}\z/) || {:error, 400, "invalid_request", "tx_hash must be 1-200 visible characters"},
         true <- payment["status"] in @open || {:error, 409, "payment_closed", "this payment is #{payment["status"]}"},
         :ok <- module!(config).submit_tx(config, payment, tx_hash) do
      GenServer.call(__MODULE__, {:poll_soon, id})
      {:ok, payment}
    end
  end

  @doc "Ask the provider about every open payment that is due, now (also runs by itself). For tests and the admin API."
  def poll_now, do: GenServer.call(__MODULE__, :poll_now, 120_000)

  @doc "Counts for metrics: `%{by_status: %{status => n}, credited_usd: total}`."
  def stats, do: GenServer.call(__MODULE__, :stats)

  defp off, do: {:error, 404, "not_found", "payments are not configured on this gateway"}

  defp prepaid(key) do
    cond do
      Map.get(key, :source) != :managed ->
        {:error, 409, "not_prepaid", "payments credit a prepaid key created through the admin API; this key is defined in the config file"}

      not Credits.prepaid?(key) ->
        {:error, 409, "not_prepaid", "payments credit a prepaid key: one with a total budget; this key has none"}

      true ->
        :ok
    end
  end

  defp amount(n, config) when is_number(n) do
    cond do
      n < config.min_usd -> {:error, 400, "invalid_request", "amount_usd is below the smallest payment taken (#{config.min_usd})"}
      n > config.max_usd -> {:error, 400, "invalid_request", "amount_usd is above the largest payment taken (#{config.max_usd})"}
      # Whole cents: what a payer reads is what is credited.
      true -> {:ok, Float.round(n * 1.0, 2)}
    end
  end

  defp amount(_, _), do: {:error, 400, "invalid_request", "amount_usd is required: a number of US dollars"}

  defp asset(id) when is_binary(id) do
    if id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9:._\-]{0,199}\z/,
      do: {:ok, id},
      else: {:error, 400, "invalid_request", "asset is not an asset id; GET /v1/payments/assets lists them"}
  end

  defp asset(_), do: {:error, 400, "invalid_request", "asset is required: the id of the asset to pay with; GET /v1/payments/assets lists them"}

  defp refund_to(address) when is_binary(address) do
    if address =~ ~r/\A[!-~]{1,200}\z/,
      do: {:ok, address},
      else: {:error, 400, "invalid_request", "refund_to must be an address on the chain of the asset paid with"}
  end

  defp refund_to(_),
    do: {:error, 400, "invalid_request", "refund_to is required: the address on the paying chain that gets the funds back if the payment fails"}

  defp room(key) do
    if GenServer.call(__MODULE__, {:open_count, key.name}) >= @max_open_per_key do
      {:error, 429, "too_many_open_payments", "this key has #{@max_open_per_key} payments waiting for a deposit; pay one or let it expire first"}
    else
      :ok
    end
  end

  defp rate(key) do
    case RateLimit.check({:payment_quote, key.name}, @quotes_per_minute) do
      :ok -> :ok
      {:error, seconds} -> {:error, 429, "rate_limited", "too many payment requests; try again in #{seconds} s"}
    end
  end

  # ---- What is shown ---------------------------------------------------------------------

  @doc "A payment as its key holder sees it."
  def view(p) do
    %{
      id: p["id"],
      status: p["status"],
      amount_usd: p["amount_usd"],
      credited_usd: p["credited_usd"],
      detail: p["detail"],
      provider: p["provider"],
      # What to send, where, by when.
      deposit: %{
        address: p["deposit_address"],
        memo: p["deposit_memo"],
        asset: p["asset"],
        symbol: p["asset_symbol"],
        chain: p["asset_chain"],
        amount: p["amount_in_formatted"],
        amount_units: p["amount_in"],
        min_amount_units: p["min_amount_in"],
        amount_usd: p["amount_in_usd"]
      },
      refund_to: p["refund_to"],
      deadline: p["deadline"],
      time_estimate_s: p["time_estimate_s"],
      provider_status: p["provider_status"],
      tx: p["tx"] || [],
      created_at: p["created_at"],
      updated_at: p["updated_at"]
    }
  end

  @doc "A payment as the admin API shows it: the same, with the key's name and the reference it is credited under."
  def admin_view(p),
    do: p |> view() |> Map.merge(%{key: p["key"], reference: reference(p), recipient: p["recipient"]})

  @doc "The reference a payment is credited under: the provider's name and the deposit address (and memo), which no two payments share."
  def reference(p) do
    memo = if p["deposit_memo"], do: ":" <> p["deposit_memo"], else: ""
    text = "#{p["provider"]}:#{p["deposit_address"]}#{memo}"
    # A top-up reference is at most 200 visible characters.
    if byte_size(text) <= 200 and text =~ ~r/\A[!-~]+\z/, do: text, else: "#{p["provider"]}:sha256:" <> OmnigateControl.sha256_hex(text)
  end

  # ---- Server ----------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    payments = load(path)
    if payments != [], do: Logger.info("loaded #{length(payments)} payments from #{path}")
    Process.send_after(self(), :tick, 1_000)
    {:ok, %{path: path, payments: payments, polling: nil}}
  end

  @impl true
  def handle_call({:insert, payment}, _from, state) do
    case save(state, [payment | state.payments]) do
      {:ok, state} ->
        Audit.system("payment.create", payment["key"], "ok", payment: audit(payment))
        {:reply, {:ok, payment}, state}

      {:error, state} ->
        {:reply, {:error, 500, "storage_error", "the payment could not be stored; nothing was started. Do not send funds to an address you were not given."},
         state}
    end
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Enum.find(state.payments, &(&1["id"] == id)), state}

  def handle_call({:list, name, limit}, _from, state) do
    list = if name, do: Enum.filter(state.payments, &(&1["key"] == name)), else: state.payments
    {:reply, Enum.take(list, limit), state}
  end

  def handle_call({:open_count, name}, _from, state) do
    {:reply, Enum.count(state.payments, &(&1["key"] == name and &1["status"] == "awaiting_deposit")), state}
  end

  def handle_call({:poll_soon, id}, _from, state) do
    payments = Enum.map(state.payments, &if(&1["id"] == id and &1["status"] in @open, do: Map.put(&1, "next_poll_at", 0), else: &1))
    {:reply, :ok, %{state | payments: payments}}
  end

  def handle_call(:poll_now, _from, state) do
    case config() do
      nil ->
        {:reply, :ok, state}

      config ->
        due = Enum.filter(state.payments, &(&1["status"] in @open))
        {:reply, :ok, apply_results(state, ask(config, due), config)}
    end
  end

  def handle_call(:stats, _from, state) do
    by_status = Enum.frequencies_by(state.payments, & &1["status"])
    credited = state.payments |> Enum.map(&(&1["credited_usd"] || 0.0)) |> Enum.sum()
    {:reply, %{by_status: by_status, credited_usd: credited}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)
    now = System.os_time(:second)

    with %{} = config <- config(),
         nil <- state.polling,
         [_ | _] = due <- Enum.filter(state.payments, &(&1["status"] in @open and (&1["next_poll_at"] || 0) <= now)) do
      # The provider is asked outside this process, which must stay answerable.
      store = self()
      {_pid, ref} = spawn_monitor(fn -> send(store, {:polled, ask(config, Enum.take(due, 25))}) end)
      {:noreply, %{state | polling: ref}}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:polled, results}, state) do
    case config() do
      nil -> {:noreply, state}
      config -> {:noreply, apply_results(state, results, config)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{polling: ref} = state), do: {:noreply, %{state | polling: nil}}
  def handle_info(_other, state), do: {:noreply, state}

  # One question per open payment: `[{id, {:ok, outcome} | {:error, reason}}]`.
  defp ask(config, payments) do
    module = module!(config)

    Enum.map(payments, fn payment ->
      answer =
        try do
          module.status(config, payment)
        rescue
          e -> {:error, {:raised, Exception.message(e)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {payment["id"], answer}
    end)
  end

  defp apply_results(state, results, config) do
    now = System.os_time(:second)

    payments =
      Enum.map(state.payments, fn payment ->
        case List.keyfind(results, payment["id"], 0) do
          {_, answer} -> if payment["status"] in @open, do: settle(payment, answer, config, now), else: payment
          nil -> payment
        end
      end)

    if payments == state.payments do
      state
    else
      case save(state, payments) do
        {:ok, state} -> state
        # Not stored: asked again at the next tick, and a credit is applied once whatever happens.
        {:error, state} -> state
      end
    end
  end

  # What one answer makes of one open payment.
  defp settle(payment, {:ok, %{state: :settled, delivered_usd: delivered} = outcome}, _config, _now) when is_number(delivered) and delivered > 0 do
    # What arrived is what is credited: a dollar stablecoin, one to one. An
    # amount far above what was asked for is not believed beyond it.
    credit = Float.round(min(delivered, payment["amount_usd"] * 1.05), 6)

    attrs = %{"amount_usd" => credit, "reference" => reference(payment), "source" => payment["provider"]}

    case Keys.topup(payment["key"], attrs) do
      {:ok, _key, _done} ->
        Audit.system("payment.settle", payment["key"], "ok", payment: payment |> audit() |> Map.put("credited_usd", credit))
        Logger.info("payment #{payment["id"]}: settled, #{credit} credited to #{payment["key"]}")
        finish(payment, outcome, "settled", %{"credited_usd" => credit, "detail" => nil})

      {:error, 500, _, _} ->
        # The key store could not be written: nothing is credited yet; ask again.
        later(payment, outcome, 30)

      {:error, 409, "reference_conflict", _} = conflict ->
        # This payment was credited before (the provider now reports another
        # amount, or the record of it was lost): what was credited then stands.
        case Enum.find(Keys.topups(@max_payments), &(&1["reference"] == reference(payment) and &1["key"] == payment["key"])) do
          %{"amount_usd" => credited} -> finish(payment, outcome, "settled", %{"credited_usd" => credited, "detail" => nil})
          nil -> uncredited(payment, outcome, delivered, conflict)
        end

      error ->
        uncredited(payment, outcome, delivered, error)
    end
  end

  defp settle(payment, {:ok, %{state: state} = outcome}, _config, _now) when state in [:refunded, :failed] do
    Audit.system("payment.#{state}", payment["key"], "ok", payment: audit(payment))
    finish(payment, outcome, Atom.to_string(state), %{"detail" => outcome.detail})
  end

  defp settle(payment, {:ok, %{state: state} = outcome}, config, now) when state in [:awaiting_deposit, :processing] do
    cond do
      # Nothing came, and the address is no longer watched.
      state == :awaiting_deposit and now > payment["deadline_at"] + @grace_s ->
        finish(payment, outcome, "expired", %{"detail" => "no deposit arrived before the deadline"})

      true ->
        payment
        |> Map.merge(%{"status" => Atom.to_string(state), "provider_status" => outcome.raw, "detail" => outcome.detail, "tx" => outcome.tx})
        |> touch(payment)
        |> schedule(config, now)
    end
  end

  # Settled without an amount, or an answer that is not believed: ask again.
  defp settle(payment, {:ok, outcome}, _config, _now), do: later(payment, outcome, 60)

  defp settle(payment, {:error, reason}, config, now) do
    if rem(payment["polls"] || 0, 20) == 0,
      do: Logger.warning("payment #{payment["id"]}: the provider could not be asked (#{inspect(reason) |> String.slice(0, 160)}); will ask again")

    cond do
      # Never heard of again, long after its deadline: nothing can come of it.
      payment["status"] == "awaiting_deposit" and now > payment["deadline_at"] + 24 * 3_600 ->
        payment
        |> Map.merge(%{
          "status" => "expired",
          "detail" => "no deposit was seen, and the provider could not be asked after the deadline",
          "updated_at" => now_iso()
        })
        |> Map.delete("next_poll_at")

      true ->
        schedule(payment, config, now)
    end
  end

  defp uncredited(payment, outcome, delivered, {:error, _status, code, message}) do
    Audit.system("payment.settle", payment["key"], "uncredited", payment: audit(payment))
    Logger.error("payment #{payment["id"]}: #{delivered} arrived for key #{payment["key"]}, which could not be credited (#{code}). Nothing was credited.")
    finish(payment, outcome, "settled", %{"credited_usd" => nil, "detail" => "the funds arrived, but the key could not be credited: #{message}"})
  end

  defp finish(payment, outcome, status, changes) do
    payment
    |> Map.merge(%{"status" => status, "provider_status" => outcome.raw, "tx" => outcome.tx, "updated_at" => now_iso()})
    |> Map.merge(changes)
    |> Map.delete("next_poll_at")
  end

  defp later(payment, outcome, seconds) do
    payment
    |> Map.merge(%{
      "provider_status" => outcome.raw,
      "detail" => outcome.detail,
      "next_poll_at" => System.os_time(:second) + seconds,
      "polls" => (payment["polls"] || 0) + 1
    })
    |> touch(payment)
  end

  # `updated_at` moves only when something a reader sees has changed.
  defp touch(changed, before) do
    if Map.take(changed, ~w(status provider_status detail tx)) == Map.take(before, ~w(status provider_status detail tx)),
      do: changed,
      else: Map.put(changed, "updated_at", now_iso())
  end

  # The first polls come at the configured interval, later ones further apart.
  defp schedule(payment, config, now) do
    polls = (payment["polls"] || 0) + 1
    gap = config.poll_interval_s * if(polls <= 20, do: 1, else: min(div(polls, 10), 20))
    Map.merge(payment, %{"polls" => polls, "next_poll_at" => now + gap})
  end

  defp audit(payment), do: %{"id" => payment["id"], "amount_usd" => payment["amount_usd"], "asset" => payment["asset"], "reference" => reference(payment)}

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # ---- Persistence -----------------------------------------------------------------------

  defp load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"payments" => list}} when is_list(list) <- JSON.decode(text) do
      for %{"id" => id, "key" => key, "status" => status, "deposit_address" => _} = payment when is_binary(id) and is_binary(key) and is_binary(status) <- list,
          do: payment
    else
      {:error, :enoent} ->
        []

      other ->
        # A payment someone is about to pay must not be forgotten silently.
        raise "cannot read the payment store #{path}: #{inspect(other) |> String.slice(0, 200)}"
    end
  end

  defp save(state, payments) do
    cutoff = System.os_time(:second) - @keep_ended_s

    kept =
      payments
      |> Enum.reject(fn p -> p["status"] not in @open and ended_at(p) < cutoff end)
      |> Enum.take(@max_payments)

    body = JSON.encode!(%{"version" => 1, "payments" => kept})
    tmp = state.path <> ".tmp"

    result =
      with :ok <- File.mkdir_p(Path.dirname(state.path)),
           {:ok, io} <- File.open(tmp, [:write, :binary]),
           :ok <- IO.binwrite(io, body),
           :ok <- :file.datasync(io),
           :ok <- File.close(io),
           _ <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, state.path) do
        :ok
      end

    case result do
      :ok ->
        {:ok, %{state | payments: kept}}

      error ->
        Logger.error("cannot write #{state.path}: #{inspect(error)}")
        {:error, state}
    end
  end

  defp ended_at(payment) do
    case DateTime.from_iso8601(payment["updated_at"] || "") do
      {:ok, at, _} -> DateTime.to_unix(at)
      _ -> System.os_time(:second)
    end
  end
end
