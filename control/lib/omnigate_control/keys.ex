defmodule OmnigateControl.Keys do
  @moduledoc """
  Gateway keys created through the admin API ("managed" keys), next to the
  ones written in the config file.

  They live in a small JSON file (`OMNIGATE_KEYS`, default `data/keys.json`)
  that is rewritten atomically on every change and loaded at boot. Only the
  SHA-256 of a key is ever stored: the key itself is returned once, by
  `create/1` and `rotate/1`, and cannot be recovered afterwards. (A key's
  optional webhook signing secret is stored as given, because signing needs
  the secret itself.)

  `ConfigStore.get().keys` is the merged view of both sources, so the rest
  of the control plane, and the snapshot sent to data planes, treat managed
  keys exactly like file keys.

  Rotating a key replaces its secret but keeps its record: the hashes of
  earlier secrets are remembered (never accepted again) so that the key's
  spend, budget and media jobs carry over.

  ## Top-ups

  `topup/2` adds an amount to a key's total budget under a caller-chosen
  reference (a payment id, a transaction hash). The budget and the reference
  are written in the same file write, so a top-up is either applied and
  remembered or neither; the same reference sent again changes nothing and
  answers with what the first call did. The newest #{10_000} references are
  kept (in the same file, under `"topups"`); one older than that would be
  credited again.

  ## Credit

  A key with a total budget is prepaid: its budget is credit, and
  `OmnigateControl.Credits` is the rule it follows (a burn multiplier, two
  kinds of credit, a weekly bonus). This module keeps each such key's credit
  state next to the key (`"credits"`), brings it up to date at every top-up
  and whenever `checkpoint/0` is called, and credits a week's bonus as a
  top-up of its own, under a reference that names the key and the week.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{ConfigStore, Credits, Ledger}

  # `\A...\z`, not `^...$`: `$` also matches before a trailing newline, and a
  # name ends up in log lines, file names and the audit log.
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @fields [
    :budget_usd,
    :budget_period,
    :rpm,
    :max_concurrent,
    :models,
    :max_open_jobs,
    :max_jobs_per_day,
    :webhook_secret,
    :disabled,
    :privacy,
    :burn_multiplier
  ]
  # Where a top-up came from, as the caller names it: a payment provider, "admin".
  @source_format ~r/\A[a-z0-9][a-z0-9_.-]{0,39}\z/
  @max_old_hashes 50
  @max_topups 10_000
  @max_topup_usd 1.0e9
  # Printable ASCII without spaces: fits a transaction hash, a payment
  # provider's id, a UUID; goes into the audit log as it is.
  @reference_format ~r/\A[!-~]{1,200}\z/

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Managed keys, in the shape `ConfigStore` uses for file keys."
  def managed, do: :persistent_term.get({__MODULE__, :managed}, [])

  @doc "Create a key. Returns `{:ok, key, raw_key}`; the raw key is not kept."
  def create(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:create, attrs})

  @doc "Change `budget_usd`, `budget_period`, `rpm`, `models`, `disabled`, `webhook_secret` or `privacy` of a managed key."
  def update(name, attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:update, name, attrs})

  @doc "Give a managed key a new secret. Returns `{:ok, key, raw_key}`; the old secret stops working."
  def rotate(name), do: GenServer.call(__MODULE__, {:rotate, name})

  @doc """
  Add `amount_usd` to a managed key's total budget, once per `reference`.
  Returns `{:ok, key, topup}`; `topup["replayed"]` is true when the reference
  had been applied before and nothing was added now.

  `attrs` may also carry `"source"` (who the credit came from, "admin" by
  default).
  """
  def topup(name, attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:topup, name, attrs})

  @doc """
  Bring the credit of every prepaid managed key up to now: sample the
  balances for the weekly average and credit the bonus of every week that
  has ended. Returns `{:ok, bonuses}`, the bonuses credited as top-up
  records. Run by `OmnigateControl.Credits.Sampler`; safe to call at any
  time and any number of times.
  """
  def checkpoint, do: GenServer.call(__MODULE__, :checkpoint, 60_000)

  @doc "Applied top-ups and bonuses, newest first: at most `limit`, for one key when `name` is given."
  def topups(limit \\ 100, name \\ nil), do: GenServer.call(__MODULE__, {:topups, limit, name})

  @doc "Remove a managed key. Its usage stays in the ledger."
  def delete(name), do: GenServer.call(__MODULE__, {:delete, name})

  # -- lookups over the merged view -------------------------------------------

  @doc "The key (from either source) with this name, or nil."
  def find(name), do: Enum.find(ConfigStore.get().keys, &(&1.name == name))

  @doc "The key whose current secret hashes to `hash`, or nil."
  def find_current(hash), do: Enum.find(ConfigStore.get().keys, &(&1.key_sha256 == hash))

  @doc "The key that owns `hash`: its current secret or one it had before a rotation."
  def find_owner(hash), do: Enum.find(ConfigStore.get().keys, &(hash in hashes(&1)))

  @doc "Every hash usage may be recorded under for this key: the current one first."
  def hashes(key), do: [key.key_sha256 | Map.get(key, :old_hashes, [])]

  @doc "Ledger totals for a key, across rotations (those too long ago to have kept their hash included)."
  def totals(key) do
    key
    |> hashes()
    |> Enum.map(&Ledger.totals/1)
    |> Kernel.++(List.wrap(carried(key)))
    |> Enum.reduce(fn t, sum -> Map.merge(sum, t, fn _field, a, b -> if(is_number(a) and is_number(b), do: a + b, else: a) end) end)
  end

  # Lifetime totals of the secrets this key no longer lists (see `rotate`),
  # in the shape of `Ledger.totals/1`; nil when there are none.
  defp carried(key) do
    case Map.get(key, :carried_totals) do
      %{} = stored when map_size(stored) > 0 ->
        empty = Ledger.totals("")

        Map.new(empty, fn {field, zero} ->
          value = Map.get(stored, field, Map.get(stored, Atom.to_string(field)))
          {field, if(is_number(value) and is_number(zero), do: value, else: zero)}
        end)

      _ ->
        nil
    end
  end

  @doc "`total`, `monthly` or `daily`: what the key's budget covers."
  def budget_period(key), do: Map.get(key, :budget_period) || "total"

  @doc """
  Spend in the key's current budget period, across rotations. For a total
  budget that is the key's whole history, counted in credit: what the
  providers cost plus what the burn multiplier added (`credits_burned/1`).
  """
  def period_spend(key, now \\ DateTime.utc_now()) do
    case budget_period(key) do
      "total" -> credits_burned(key)
      period -> key |> hashes() |> Enum.map(&Ledger.period_spend(&1, period, now)) |> Enum.sum()
    end
  end

  @doc """
  What the key has burned of its credit over its whole history: provider
  cost plus the extra a burn multiplier added, including what was spent under
  secrets that have since dropped off the list. Equal to the cost for a key
  that was always billed at a multiplier of 1.
  """
  def credits_burned(key) do
    listed = key |> hashes() |> Enum.map(&(Ledger.spend(&1) + Ledger.credits_extra(&1))) |> Enum.sum()

    carried_cost =
      case carried(key) do
        %{cost_usd: usd} -> usd
        _ -> 0.0
      end

    carried_extra =
      case Map.get(key, :carried_totals) do
        %{"credits_extra_usd" => extra} when is_number(extra) -> extra
        _ -> 0.0
      end

    listed + carried_cost + carried_extra
  end

  @doc "ISO 8601 time at which the key's budget period ends, or nil for a total budget."
  def period_resets_at(key, now \\ DateTime.utc_now()) do
    case Ledger.period_resets_at(budget_period(key), now) do
      nil -> nil
      at -> DateTime.to_iso8601(at)
    end
  end

  @doc """
  True when the key has a budget and has spent it in the current period. A
  monthly or daily key therefore unblocks by itself when the period turns.
  """
  def over_budget?(key, now \\ DateTime.utc_now())
  def over_budget?(%{budget_usd: nil}, _now), do: false
  def over_budget?(key, now), do: period_spend(key, now) >= key.budget_usd

  def disabled?(key), do: Map.get(key, :disabled, false) == true

  @doc "How many unfinished jobs the key may have at once: its own setting, else the media default. 0 = no limit."
  def max_open_jobs(key) do
    case Map.get(key, :max_open_jobs) do
      nil -> ConfigStore.get().media |> Map.get(:max_open_jobs, 100)
      n -> n
    end
  end

  @doc "How many jobs the key may create per UTC day: its own setting, else the media default. 0 = no limit."
  def max_jobs_per_day(key) do
    case Map.get(key, :max_jobs_per_day) do
      nil -> ConfigStore.get().media |> Map.get(:max_jobs_per_day, 10_000)
      n -> n
    end
  end

  @doc """
  What a key's rate limits are counted under: the hash of its current
  secret, which is also what the data plane counts by. Two keys never share
  it (names in a config file are not checked for uniqueness), and a rotation
  starts a new allowance in both processes alike.
  """
  def identity(key), do: key.key_sha256

  @doc "`active`, `blocked` (budget spent) or `disabled` (switched off by an operator)."
  def state(key) do
    cond do
      disabled?(key) -> "disabled"
      over_budget?(key) -> "blocked"
      true -> "active"
    end
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    {keys, topups} = load(path)
    publish(keys)
    if keys != [], do: Logger.info("loaded #{length(keys)} managed keys from #{path}")
    # `topups`: newest first. `clock` (unix seconds) exists for tests.
    {:ok, %{path: path, keys: keys, topups: topups, clock: Keyword.get(opts, :clock, &now_s/0)}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    with {:ok, name} <- validate_name(attrs["name"]),
         :ok <- unused(name, state),
         {:ok, fields} <- validate_fields(attrs, @fields) do
      raw = new_secret()

      key =
        Map.merge(
          %{
            name: name,
            key_sha256: OmnigateControl.sha256_hex(raw),
            budget_usd: nil,
            budget_period: "total",
            rpm: 0,
            max_concurrent: 0,
            models: nil,
            max_open_jobs: nil,
            max_jobs_per_day: nil,
            webhook_secret: nil,
            disabled: false,
            privacy: nil,
            source: :managed,
            created_at: now_iso(),
            old_hashes: [],
            carried_totals: %{},
            burn_multiplier: nil,
            credits: nil
          },
          fields
        )

      commit(state, state.keys ++ [key], {:ok, key, raw})
    else
      {:error, _, _, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:update, name, attrs}, _from, state) do
    with {:ok, key} <- managed_key(name, state),
         {:ok, fields} <- validate_fields(attrs, @fields) do
      # (A key that has no credit state yet gets one at its first top-up,
      # not because its rate limit was changed.)
      {rolled, bonuses} = if is_map(Map.get(key, :credits)), do: roll(key, state), else: {key, []}
      updated = rolled |> Map.merge(fields) |> rebudget(rolled)
      commit_credit(state, updated, {:ok, updated}, bonuses)
    else
      {:error, _, _, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:rotate, name}, _from, state) do
    case managed_key(name, state) do
      {:ok, key} ->
        raw = new_secret()
        {old, dropped} = Enum.split([key.key_sha256 | key.old_hashes], @max_old_hashes)

        # Usage is found by hash. A hash that drops off the list takes its
        # lifetime totals along in `carried_totals`, so that a key's spend
        # (and with it a total budget) does not shrink at its 51st rotation.
        carried =
          Enum.reduce(dropped, Map.get(key, :carried_totals) || %{}, fn hash, sum ->
            hash
            |> Ledger.totals()
            |> Enum.filter(fn {_field, v} -> is_number(v) end)
            |> Map.new(fn {field, v} -> {Atom.to_string(field), v} end)
            |> Map.merge(sum, fn _field, a, b -> if(is_number(b), do: a + b, else: a) end)
            |> Map.update("credits_extra_usd", Ledger.credits_extra(hash), &(&1 + Ledger.credits_extra(hash)))
          end)

        updated = key |> Map.merge(%{key_sha256: OmnigateControl.sha256_hex(raw), old_hashes: old}) |> Map.put(:carried_totals, carried)
        commit(state, replace(state.keys, updated), {:ok, updated, raw})

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:topup, name, attrs}, _from, state) do
    with {:ok, key} <- managed_key(name, state),
         {:ok, amount} <- validate_amount(attrs["amount_usd"]),
         {:ok, reference} <- validate_reference(attrs["reference"]),
         {:ok, source} <- validate_source(attrs["source"]) do
      case Enum.find(state.topups, &(&1["reference"] == reference)) do
        # The same payment again (a retry, a watcher that restarted): what
        # the first call did, and nothing added.
        %{"key" => ^name, "amount_usd" => ^amount} = done ->
          {:reply, {:ok, key, Map.put(done, "replayed", true)}, state}

        %{} ->
          {:reply,
           {:error, 409, "reference_conflict", "the reference #{inspect(reference)} was already used for another key or another amount; nothing was added"},
           state}

        nil ->
          apply_topup(state, key, amount, reference, source)
      end
    else
      {:error, _, _, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:topups, limit, name}, _from, state) do
    list = if name, do: Enum.filter(state.topups, &(&1["key"] == name)), else: state.topups
    {:reply, Enum.take(list, limit), state}
  end

  def handle_call(:checkpoint, _from, state) do
    earning? = Credits.settings().bonus_annual_rate > 0

    {keys, bonuses, changed} =
      Enum.reduce(state.keys, {[], [], false}, fn key, {keys, bonuses, changed} ->
        # Nothing to sample for a key that holds no credit, and nothing to
        # say about any key while the ledger is starting. A prepaid key that
        # was never topped up has no state yet: it gets one here, while a
        # bonus rate is set, so that the budget it was created with earns too.
        with true <- Credits.prepaid?(key),
             {:ok, burned} <- burned_now(key),
             true <- samples?(Map.get(key, :credits), key.budget_usd - burned, earning?) do
          {rolled, won} = roll(key, state)
          {[rolled | keys], bonuses ++ won, changed or rolled != key}
        else
          _ -> {[key | keys], bonuses, changed}
        end
      end)

    if changed do
      # `bonuses` is oldest first; the list of top-ups newest first.
      topups = Enum.take(Enum.reverse(bonuses) ++ state.topups, @max_topups)

      case commit(state, Enum.reverse(keys), {:ok, bonuses}, topups) do
        {:reply, {:ok, _} = reply, new_state} ->
          Enum.each(bonuses, &announce(&1, new_state.keys))
          {:reply, reply, new_state}

        other ->
          other
      end
    else
      {:reply, {:ok, []}, state}
    end
  end

  def handle_call({:delete, name}, _from, state) do
    case managed_key(name, state) do
      {:ok, key} -> commit(state, Enum.reject(state.keys, &(&1.name == key.name)), :ok)
      error -> {:reply, error, state}
    end
  end

  # A top-up is credit bought in advance. Only a total budget is that: a
  # monthly or daily budget is an allowance that starts over by itself, and a
  # key without a budget has nothing to add to.
  defp apply_topup(state, key, amount, reference, source) do
    cond do
      is_nil(key.budget_usd) or budget_period(key) != "total" ->
        {:reply,
         {:error, 409, "not_prepaid",
          "top-ups add to a total budget: give the key \"budget_usd\" (0 is fine) with \"budget_period\": \"total\" first; nothing was added"}, state}

      key.budget_usd + amount > 1.0e12 ->
        {:reply, {:error, 400, "invalid_request", "the budget would exceed 1e12 dollars; nothing was added"}, state}

      true ->
        # The key's credit as it stands now (closing any week that has
        # ended, with its bonus), then the new credit on top.
        {rolled, bonuses} = roll(key, state)
        updated = Map.merge(rolled, %{budget_usd: rolled.budget_usd + amount, credits: Credits.credit(rolled.credits, amount)})

        done = %{
          "reference" => reference,
          "key" => key.name,
          "amount_usd" => amount,
          "budget_usd" => updated.budget_usd,
          "at" => now_iso(),
          "source" => source
        }

        commit_credit(state, updated, {:ok, updated, Map.put(done, "replayed", false)}, bonuses ++ [done])
    end
  end

  # -- credit ---------------------------------------------------------------------

  # A key's lifetime burn, or `:error` while the ledger cannot say (it is
  # starting): a balance is never worked out from a half-loaded ledger.
  defp burned_now(key) do
    if Ledger.ready?(), do: {:ok, credits_burned(key)}, else: :error
  rescue
    _ -> :error
  end

  # ... or, where the answer may not wait, what the key's state last saw.
  defp burned_or(key) do
    case burned_now(key) do
      {:ok, burned} -> burned
      :error -> get_in(Map.get(key, :credits) || %{}, ["burned"]) || 0.0
    end
  end

  defp samples?(%{"balance" => balance, "integral" => integral}, _held, _earning?), do: balance > 0 or integral > 0
  defp samples?(_none, held, earning?), do: earning? and held > 0

  # The state a key has, or the one it starts with.
  defp credit_state(key, burned, now), do: Map.get(key, :credits) || Credits.new(key.budget_usd - burned, burned, now)

  # A prepaid key with its credit brought up to now: the burn since the
  # last look drawn, the balance sampled, and every week that ended closed
  # with its bonus (as top-up records, oldest first, already in the key's
  # budget). Any other key comes back as it is.
  defp roll(key, state) do
    if Credits.prepaid?(key) do
      now = state.clock.()
      burned = burned_or(key)
      credited? = fn week -> Enum.any?(state.topups, &(&1["reference"] == Credits.bonus_reference(key.name, week))) end
      {credits, won} = key |> credit_state(burned, now) |> Credits.advance(now, burned, Credits.settings().bonus_annual_rate, credited?)
      records = bonus_records(key.name, won, key.budget_usd)
      budget = key.budget_usd + (won |> Enum.map(&elem(&1, 1)) |> Enum.sum())
      {Map.merge(key, %{credits: credits, budget_usd: budget}), records}
    else
      {key, []}
    end
  end

  # An operator changed the budget or its period by hand; `before` is the
  # key as `roll/2` left it.
  defp rebudget(updated, before) do
    cond do
      not Credits.prepaid?(updated) ->
        Map.put(updated, :credits, nil)

      not Credits.prepaid?(before) ->
        # Starts at the next look.
        Map.put(updated, :credits, nil)

      is_map(Map.get(before, :credits)) and updated.budget_usd != before.budget_usd ->
        Map.put(updated, :credits, Credits.adjust(before.credits, updated.budget_usd - before.budget_usd))

      true ->
        updated
    end
  end

  # Store one changed key together with the credit records that go with the
  # change (oldest first), then say so where credit is recorded.
  defp commit_credit(state, updated, reply, records) do
    topups = Enum.take(Enum.reverse(records) ++ state.topups, @max_topups)

    case commit(state, replace(state.keys, updated), reply, topups) do
      {:reply, ok, new_state} = result when elem(ok, 0) == :ok ->
        Enum.each(records, &announce(&1, new_state.keys))
        result

      other ->
        other
    end
  end

  defp bonus_records(name, won, budget) do
    {records, _} =
      Enum.map_reduce(won, budget, fn {week, amount, at}, budget ->
        {%{
           "reference" => Credits.bonus_reference(name, week),
           "key" => name,
           "amount_usd" => amount,
           "budget_usd" => budget + amount,
           "at" => at |> DateTime.from_unix!() |> DateTime.to_iso8601(),
           "source" => "bonus"
         }, budget + amount}
      end)

    records
  end

  # Credit was added: a line in the audit log (for a bonus, which nobody
  # asked for) and one in the usage history, so that a statement read from
  # the events feed is complete. Neither may undo the top-up, which is on
  # disk already.
  defp announce(done, keys) do
    key = Enum.find(keys, &(&1.name == done["key"]))

    if done["source"] == "bonus" do
      OmnigateControl.Audit.system("key.bonus", done["key"], "ok", topup: Map.take(done, ["reference", "amount_usd", "budget_usd"]))
      Logger.info("credit: #{done["key"]} earned a bonus of #{Float.round(done["amount_usd"], 6)} (#{done["reference"]})")
    end

    if key do
      Ledger.record_credit(%{
        "id" => "credit:" <> done["reference"],
        "key_sha256" => key.key_sha256,
        "amount_usd" => done["amount_usd"],
        "source" => done["source"],
        "reference" => done["reference"],
        "budget_usd" => done["budget_usd"]
      })
    end

    :ok
  rescue
    e -> Logger.warning("credit: #{inspect(done["reference"])} is applied, but could not be written to the usage history: #{Exception.message(e)}")
  catch
    :exit, reason -> Logger.warning("credit: #{inspect(done["reference"])} is applied, but could not be written to the usage history: #{inspect(reason)}")
  end

  # Disk first: a change that cannot be saved is not applied.
  defp commit(state, keys, reply, topups \\ nil) do
    topups = topups || state.topups

    case save(state.path, keys, topups) do
      :ok ->
        publish(keys)
        {:reply, reply, %{state | keys: keys, topups: topups}}

      {:error, reason} ->
        Logger.error("cannot write #{state.path}: #{inspect(reason)}")
        {:reply, {:error, 500, "storage_error", "the key store could not be written; nothing was changed"}, state}
    end
  end

  defp publish(keys) do
    :persistent_term.put({__MODULE__, :managed}, keys)
    ConfigStore.warn_shadowed()
  end

  defp replace(keys, updated), do: Enum.map(keys, &if(&1.name == updated.name, do: updated, else: &1))

  defp managed_key(name, state) do
    case Enum.find(state.keys, &(&1.name == name)) do
      nil ->
        if Enum.any?(ConfigStore.file_keys(), &(&1.name == name)) do
          {:error, 409, "read_only_key", "the key #{inspect(name)} is defined in the config file; edit the file to change it"}
        else
          {:error, 404, "key_not_found", "no key named #{inspect(name)}"}
        end

      key ->
        {:ok, key}
    end
  end

  defp unused(name, state) do
    if Enum.any?(state.keys ++ ConfigStore.file_keys(), &(&1.name == name)) do
      {:error, 409, "key_exists", "a key named #{inspect(name)} already exists"}
    else
      :ok
    end
  end

  # -- validation -----------------------------------------------------------------

  defp validate_name(name) when is_binary(name) do
    if name =~ @name_format do
      {:ok, name}
    else
      invalid("name must be 1-64 characters: letters, digits, '.', '_' or '-', starting with a letter or digit")
    end
  end

  defp validate_name(_), do: invalid("name is required")

  # Only fields present in the request are validated and returned.
  defp validate_fields(attrs, allowed) do
    Enum.reduce_while(allowed, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(attrs, Atom.to_string(field)) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case validate(field, value) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, field, v)}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp validate(:budget_usd, nil), do: {:ok, nil}
  defp validate(:budget_usd, n) when is_number(n) and n >= 0 and n <= 1.0e12, do: {:ok, n * 1.0}
  defp validate(:budget_usd, _), do: invalid("budget_usd must be a number of dollars, 0 or more, or null for no budget")

  defp validate(:budget_period, nil), do: {:ok, "total"}

  defp validate(:budget_period, p) do
    if p in ConfigStore.budget_periods(), do: {:ok, p}, else: invalid("budget_period must be \"total\", \"monthly\" or \"daily\"")
  end

  defp validate(:rpm, nil), do: {:ok, 0}
  # The data plane reads `rpm` into a 32-bit field: a larger number would
  # make the config snapshot unreadable for every data plane (see
  # `ConfigStore.limits/0`).
  defp validate(:rpm, n) when is_integer(n) and n >= 0 do
    if n <= ConfigStore.limits().rpm, do: {:ok, n}, else: invalid("rpm must be at most #{ConfigStore.limits().rpm} (0 for no limit)")
  end

  defp validate(:rpm, _), do: invalid("rpm must be a whole number of requests per minute, or 0 for no limit")

  defp validate(:max_concurrent, nil), do: {:ok, 0}

  # Read by the data plane into a 32-bit field, like `rpm`.
  defp validate(:max_concurrent, n) when is_integer(n) and n >= 0 do
    max = ConfigStore.limits().max_concurrent
    if n <= max, do: {:ok, n}, else: invalid("max_concurrent must be at most #{max} (0 for the gateway default)")
  end

  defp validate(:max_concurrent, _), do: invalid("max_concurrent must be a whole number of requests in flight at once, or 0 for the gateway default")

  defp validate(:models, nil), do: {:ok, nil}

  defp validate(:models, list) when is_list(list) do
    if length(list) <= 1_000 and Enum.all?(list, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 256)) do
      {:ok, Enum.uniq(list)}
    else
      invalid("models must be a list of at most 1000 model names, or null for all models")
    end
  end

  defp validate(:models, _), do: invalid("models must be a list of model names, or null for all models")

  defp validate(:max_open_jobs, nil), do: {:ok, nil}
  defp validate(:max_open_jobs, n) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: {:ok, n}
  defp validate(:max_open_jobs, _), do: invalid("max_open_jobs must be a whole number (0 for no limit), or null for the default")

  defp validate(:max_jobs_per_day, nil), do: {:ok, nil}
  defp validate(:max_jobs_per_day, n) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: {:ok, n}
  defp validate(:max_jobs_per_day, _), do: invalid("max_jobs_per_day must be a whole number (0 for no limit), or null for the default")

  defp validate(:disabled, b) when is_boolean(b), do: {:ok, b}
  defp validate(:disabled, _), do: invalid("disabled must be true or false")

  # `true`, `false`/`null`, or the parts one by one (see `OmnigateControl.Privacy`).
  defp validate(:privacy, value) do
    case OmnigateControl.Privacy.normalize(value) do
      {:ok, privacy} -> {:ok, privacy}
      {:error, message} -> invalid(message)
    end
  end

  defp validate(:burn_multiplier, nil), do: {:ok, nil}
  defp validate(:burn_multiplier, n) when is_number(n) and n >= 0.01 and n <= 100, do: {:ok, n * 1.0}
  defp validate(:burn_multiplier, _), do: invalid("burn_multiplier must be a number from 0.01 to 100, or null for the configured one")

  defp validate(:webhook_secret, nil), do: {:ok, nil}
  defp validate(:webhook_secret, ""), do: {:ok, nil}
  defp validate(:webhook_secret, s) when is_binary(s) and byte_size(s) <= 256, do: {:ok, s}
  defp validate(:webhook_secret, _), do: invalid("webhook_secret must be a string of at most 256 characters")

  defp validate_amount(n) when is_number(n) and n > 0 and n <= @max_topup_usd, do: {:ok, n * 1.0}
  defp validate_amount(_), do: invalid("amount_usd must be a number of dollars above 0, at most #{trunc(@max_topup_usd)}")

  defp validate_reference(r) when is_binary(r) do
    if r =~ @reference_format,
      do: {:ok, r},
      else: invalid("reference must be 1-200 printable ASCII characters without spaces (a payment id or transaction hash)")
  end

  defp validate_reference(_), do: invalid("reference is required: a string that names the payment, so that sending it twice credits once")

  defp validate_source(nil), do: {:ok, "admin"}

  defp validate_source(s) when is_binary(s) do
    cond do
      s == "bonus" -> invalid("the source \"bonus\" is the gateway's own")
      s =~ @source_format -> {:ok, s}
      true -> invalid("source must be 1-40 lower-case letters, digits, '.', '_' or '-'")
    end
  end

  defp validate_source(_), do: invalid("source must be a string")

  defp invalid(message), do: {:error, 400, "invalid_request", message}

  # -- persistence ----------------------------------------------------------------

  defp new_secret, do: "og-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # Unix seconds. (`:credits_clock` exists for tests, which move time.)
  defp now_s do
    case Application.get_env(:omnigate_control, :credits_clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> System.os_time(:second)
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"keys" => list} = file} when is_list(list) <- JSON.decode(text) do
      topups =
        for %{"reference" => r, "key" => k, "amount_usd" => a} = t when is_binary(r) and is_binary(k) and is_number(a) <- List.wrap(file["topups"]) do
          Map.put(t, "amount_usd", a * 1.0)
        end

      keys =
        for %{"name" => name, "key_sha256" => hash} = k when is_binary(name) and is_binary(hash) <- list do
          %{
            name: name,
            key_sha256: hash,
            budget_usd: if(is_number(k["budget_usd"]), do: k["budget_usd"] * 1.0),
            budget_period: if(k["budget_period"] in ConfigStore.budget_periods(), do: k["budget_period"], else: "total"),
            # A file written before `rpm` was bounded may hold anything.
            rpm: if(is_integer(k["rpm"]), do: k["rpm"] |> max(0) |> min(ConfigStore.limits().rpm), else: 0),
            max_concurrent: if(is_integer(k["max_concurrent"]), do: k["max_concurrent"] |> max(0) |> min(ConfigStore.limits().max_concurrent), else: 0),
            models: if(is_list(k["models"]), do: k["models"]),
            max_open_jobs: if(is_integer(k["max_open_jobs"]) and k["max_open_jobs"] >= 0, do: k["max_open_jobs"]),
            max_jobs_per_day: if(is_integer(k["max_jobs_per_day"]) and k["max_jobs_per_day"] >= 0, do: k["max_jobs_per_day"]),
            webhook_secret: k["webhook_secret"],
            disabled: k["disabled"] == true,
            privacy: OmnigateControl.Privacy.load(k["privacy"]),
            source: :managed,
            created_at: k["created_at"],
            old_hashes: if(is_list(k["old_hashes"]), do: k["old_hashes"], else: []),
            carried_totals: if(is_map(k["carried_totals"]), do: Map.filter(k["carried_totals"], fn {f, v} -> is_binary(f) and is_number(v) end), else: %{}),
            burn_multiplier:
              if(is_number(k["burn_multiplier"]) and k["burn_multiplier"] >= 0.01 and k["burn_multiplier"] <= 100, do: k["burn_multiplier"] * 1.0),
            credits: Credits.load(k["credits"])
          }
        end

      {keys, Enum.take(topups, @max_topups)}
    else
      {:error, :enoent} ->
        {[], []}

      other ->
        # Refuse to start over a file we cannot read: writing a fresh one would
        # silently revoke every managed key.
        raise "cannot read the key store #{path}: #{inspect(other)}"
    end
  end

  # Temp file, fsync, rename: a crash never leaves half a file in place.
  defp save(path, keys, topups) do
    body =
      JSON.encode!(%{
        "version" => 1,
        # Applied top-ups, newest first (see "Top-ups" above). A reader that
        # does not know the field ignores it.
        "topups" => topups,
        # (The two credit fields are written only when a key has them, so a
        # store without credit settings is the file it always was.)
        "keys" =>
          Enum.map(keys, fn k ->
            k
            |> Map.delete(:source)
            |> Map.reject(fn {field, v} -> field in [:burn_multiplier, :credits] and is_nil(v) end)
            |> Map.new(fn {field, v} -> {Atom.to_string(field), v} end)
          end)
      })

    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(tmp, [:write, :binary]),
         :ok <- IO.binwrite(io, body),
         :ok <- :file.datasync(io),
         :ok <- File.close(io),
         _ <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end
end
