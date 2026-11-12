defmodule OmnigateControl.Credits do
  @moduledoc """
  The one rule prepaid credit follows, whoever paid for it and however.

  A **prepaid key** is a key with a total budget (`budget_usd` set,
  `budget_period` "total"). What it holds is credit:

      1 credit      = 1 US dollar, at the moment a top-up is applied
      balance       = top-ups + bonuses − burns
      burn          = what the provider cost × the burn multiplier
      weekly bonus  = average balance over the week
                      × the annual bonus rate ÷ 52

  A key at or below zero is blocked (`402 budget_exceeded`) until it is
  credited again. Credit cannot be withdrawn or refunded; there is no call
  that pays any out.

  Keys with a monthly or daily budget, and keys without one, are not prepaid:
  none of this applies to them and they are billed the provider cost as
  before.

  ## Settings (`"credits"` in the config; all optional)

    * `burn_multiplier` — default 1.0, which is exactly the behaviour without
      this module. A key may carry its own `burn_multiplier`, which wins.
    * `bonus_annual_rate` — default 0 (no bonus). The rate in force when a
      week closes is the one applied to that week; it is a setting, not a
      promise.
    * `sample_interval_s` — how often balances are sampled for the weekly
      average while a bonus rate is set (default 900).

  All credit is the same: whatever a prepaid key holds earns the bonus,
  wherever it came from (the budget it was created with, a top-up, a
  payment, an earlier bonus, which therefore compounds).

  ## Arithmetic

  All amounts are IEEE-754 doubles in US dollars, like every cost in the
  ledger; nothing is rounded when it is stored or compared. Views round to
  six decimals. A bonus below one millionth of a dollar is not credited.

  ## The weekly average

  Weeks are ISO weeks in UTC (Monday 00:00 to Monday 00:00). The average is
  the integral of the balance over the week (below zero counts as zero)
  divided by the length of the week, so a key that held credit for half the week earns half. The
  integral is built from samples: between two samples the balance is taken
  to have moved in a straight line. Samples are taken at every top-up and
  every `sample_interval_s`; if the control plane was not running, the gap is
  one long straight line, and every week that ended meanwhile is closed and
  credited when it starts again, once each (the reference of a bonus is
  `bonus:<key>:<ISO week>`, and a reference is only ever credited once).

  The state per key (in the key store, under `"credits"`) is a small map:
  `balance`, `burned` (the key's lifetime burn the balance already accounts
  for), `at` (when), `integral` (dollar-seconds of balance in the week `at`
  falls in), and `last_bonus`.
  """
  alias OmnigateControl.{ConfigStore, Keys}

  @week_s 604_800
  @min_bonus 1.0e-6
  @defaults %{burn_multiplier: 1.0, bonus_annual_rate: 0.0, sample_interval_s: 900}
  @known ~w(burn_multiplier bonus_annual_rate sample_interval_s)

  # ---- Settings ------------------------------------------------------------

  @doc "The settings with nothing configured."
  def defaults, do: @defaults

  @doc "The `\"credits\"` section of a config, validated; raises `ArgumentError` on anything not understood."
  def normalize!(nil), do: @defaults

  def normalize!(%{} = raw) do
    case Map.keys(raw) -- @known do
      [] -> :ok
      unknown -> raise ArgumentError, "credits: unknown field(s) #{Enum.join(Enum.sort(unknown), ", ")}; known: #{Enum.join(@known, ", ")}"
    end

    %{
      burn_multiplier: multiplier!(raw["burn_multiplier"], "credits.burn_multiplier") || 1.0,
      bonus_annual_rate:
        case raw["bonus_annual_rate"] do
          nil -> 0.0
          n when is_number(n) and n >= 0 and n <= 10 -> n * 1.0
          other -> raise ArgumentError, "credits.bonus_annual_rate must be a number from 0 to 10 (0.05 is 5% a year), got #{inspect(other)}"
        end,
      sample_interval_s:
        case raw["sample_interval_s"] do
          nil -> 900
          n when is_integer(n) and n >= 1 and n <= 86_400 -> n
          other -> raise ArgumentError, "credits.sample_interval_s must be a whole number of seconds from 1 to 86400, got #{inspect(other)}"
        end
    }
  end

  def normalize!(other), do: raise(ArgumentError, "credits must be an object, got #{inspect(other)}")

  @doc "A burn multiplier as a config or a key may carry it: nil, or a number from 0.01 to 100. Raises otherwise."
  def multiplier!(nil, _where), do: nil
  def multiplier!(n, _where) when is_number(n) and n >= 0.01 and n <= 100, do: n * 1.0
  def multiplier!(other, where), do: raise(ArgumentError, "#{where} must be a number from 0.01 to 100 (1 = provider cost), got #{inspect(other)}")

  @doc "The settings in force."
  def settings do
    case :persistent_term.get({ConfigStore, :config}, nil) do
      %{credits: %{} = settings} -> settings
      _ -> @defaults
    end
  end

  # ---- Which keys, and at what rate ------------------------------------------

  @doc "True for a key that holds credit: a total budget."
  def prepaid?(key), do: is_number(Map.get(key, :budget_usd)) and Keys.budget_period(key) == "total"

  @doc "What one dollar of provider cost burns for this key: its own multiplier, else the setting; 1.0 for a key that is not prepaid."
  def multiplier(key, settings \\ settings()) do
    if prepaid?(key), do: Map.get(key, :burn_multiplier) || settings.burn_multiplier, else: 1.0
  end

  @doc """
  The multiplier for whatever key owns `key_sha256` (its current secret or
  an earlier one), 1.0 when none does. For the ledger, which asks once per
  event: the table of multipliers other than 1 is kept in the calling
  process and rebuilt only when the config or the managed keys are replaced.
  """
  def multiplier_for_hash(key_sha256) do
    config = :persistent_term.get({ConfigStore, :config}, nil)
    managed = Keys.managed()

    table =
      case Process.get(:omnigate_credit_multipliers) do
        {c, m, table} ->
          if :erts_debug.same(c, config) and :erts_debug.same(m, managed), do: table, else: rebuild(config, managed)

        _ ->
          rebuild(config, managed)
      end

    Map.get(table, key_sha256, 1.0)
  end

  defp rebuild(config, managed) do
    table =
      if is_map(config) do
        settings = Map.get(config, :credits, @defaults)

        for key <- ConfigStore.get().keys, mult = multiplier(key, settings), mult != 1.0, hash <- Keys.hashes(key), into: %{} do
          {hash, mult}
        end
      else
        %{}
      end

    Process.put(:omnigate_credit_multipliers, {config, managed, table})
    table
  end

  # ---- Time --------------------------------------------------------------------

  @doc "Unix second at which the ISO week containing `unix` began (Monday 00:00 UTC)."
  def week_start(unix) when is_integer(unix) do
    # 1970-01-01 was a Thursday: three days into its week.
    Integer.floor_div(unix + 3 * 86_400, @week_s) * @week_s - 3 * 86_400
  end

  @doc "The ISO week containing `unix`, as `\"2026-W46\"`."
  def week_id(unix) when is_integer(unix) do
    {year, week} = unix |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_erl() |> :calendar.iso_week_number()
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  @doc "The reference a week's bonus for a key is credited under."
  def bonus_reference(key_name, week), do: "bonus:#{key_name}:#{week}"

  # ---- The state of one key ------------------------------------------------------

  @doc "A fresh state: `balance` of credit at `now`, with `burned` of the key's lifetime burn accounted for."
  def new(balance, burned, now) do
    %{"balance" => balance * 1.0, "burned" => burned * 1.0, "at" => now, "integral" => 0.0}
  end

  @doc "A state read from disk, or nil when it is not one."
  def load(%{"balance" => balance, "burned" => b, "at" => at} = raw) when is_number(balance) and is_number(b) and is_integer(at) do
    state = %{
      "balance" => balance * 1.0,
      "burned" => b * 1.0,
      "at" => at,
      "integral" => if(is_number(raw["integral"]), do: max(raw["integral"] * 1.0, 0.0), else: 0.0)
    }

    case raw["last_bonus"] do
      %{"week" => w, "amount_usd" => a} = last when is_binary(w) and is_number(a) -> Map.put(state, "last_bonus", Map.take(last, ["week", "amount_usd", "at"]))
      _ -> state
    end
  end

  # A state from before all credit was one kind: two balances, of which only
  # one earned. They are added up; the week under way keeps what it had.
  def load(%{"plain" => p, "eligible" => e} = raw) when is_number(p) and is_number(e) do
    raw |> Map.drop(["plain", "eligible"]) |> Map.put("balance", p + e) |> load()
  end

  def load(_), do: nil

  @doc "What is left (negative after the request that crossed zero)."
  def balance(state), do: state["balance"]

  @doc """
  Bring a state up to `now`, given the key's lifetime burn `burned_now`.

  The burn since the state's own time comes off the balance, and the
  balance's path goes into the weekly integral. Every week that ended on the
  way is closed: its bonus, at `rate` (annual), is added unless
  `credited?.(week)` says that week's bonus exists already.

  Returns `{state, bonuses}` with `bonuses` as `[{week, amount_usd, at}]`,
  oldest first. Pure: nothing is stored.
  """
  def advance(state, now, burned_now, rate, credited? \\ fn _week -> false end) when is_integer(now) do
    do_advance(state, now, burned_now * 1.0, rate, credited?, [], 0)
  end

  defp do_advance(state, now, burned_now, rate, credited?, bonuses, rounds) do
    week_end = week_start(state["at"]) + @week_s

    if now < week_end or rounds >= 1_000 do
      {step(state, max(now, state["at"]), burned_now), Enum.reverse(bonuses)}
    else
      at = state["at"]
      burn = max(burned_now - state["burned"], 0.0)
      # The share of the burn that falls before the week's end, on a straight line.
      share = if now > at, do: (week_end - at) / (now - at), else: 1.0
      state = step(state, week_end, state["burned"] + burn * share)
      week = week_id(week_end - 1)
      bonus = state["integral"] / @week_s * rate / 52

      {state, bonuses} =
        if rate > 0 and bonus >= @min_bonus and not credited?.(week) do
          state = state |> credit(bonus) |> Map.put("last_bonus", %{"week" => week, "amount_usd" => bonus, "at" => week_end})
          {state, [{week, bonus, week_end} | bonuses]}
        else
          {state, bonuses}
        end

      do_advance(Map.put(state, "integral", 0.0), now, burned_now, rate, credited?, bonuses, rounds + 1)
    end
  end

  # One straight line from the state's time to `t`, ending at burn `burned`.
  defp step(state, t, burned) do
    burn = max(burned - state["burned"], 0.0)
    before = state["balance"]
    left = before - burn
    seconds = max(t - state["at"], 0)

    Map.merge(state, %{
      "balance" => left,
      "burned" => max(burned, state["burned"]),
      "at" => max(t, state["at"]),
      "integral" => state["integral"] + area(before, left, seconds)
    })
  end

  # Dollar-seconds under a straight line from `a` down to `b` over `seconds`,
  # counting only what is above zero.
  defp area(a, _b, _seconds) when a <= 0, do: 0.0
  defp area(a, b, seconds) when b >= 0, do: (a + b) / 2 * seconds
  defp area(a, b, seconds), do: a / 2 * seconds * (a / (a - b))

  @doc "Add `amount` of credit."
  def credit(state, amount), do: %{state | "balance" => state["balance"] + amount}

  @doc "Change the balance by `delta` (an operator changed the budget)."
  def adjust(state, delta), do: %{state | "balance" => state["balance"] + delta}

  # ---- What is shown ---------------------------------------------------------------

  @doc """
  A prepaid key's credit as the admin API shows it, or nil for a key that is
  not prepaid. `burned` is the key's lifetime burn now.
  """
  def view(key, burned, now \\ System.os_time(:second)) do
    if prepaid?(key) do
      settings = settings()
      state = Map.get(key, :credits) || new(key.budget_usd - burned, burned, now)

      %{
        balance_usd: round6(key.budget_usd - burned),
        burned_usd: round6(burned),
        burn_multiplier: multiplier(key, settings),
        bonus_annual_rate: settings.bonus_annual_rate,
        last_bonus:
          case state["last_bonus"] do
            %{} = last -> %{week: last["week"], amount_usd: round6(last["amount_usd"])}
            _ -> nil
          end
      }
    end
  end

  defp round6(n), do: Float.round(n * 1.0, 6)
end
