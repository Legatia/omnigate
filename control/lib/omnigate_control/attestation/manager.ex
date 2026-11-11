defmodule OmnigateControl.Attestation.Manager do
  @moduledoc """
  Keeps the attestation of every (upstream, model) the config routes to on
  an attested upstream verified, and says what it found.

  Once a second it compares what the config wants with what it has. A pair
  that is new, or whose upstream changed, starts as `pending` and is checked
  at once; a verified pair is checked again when half of its `max_age_s` has
  passed, so that a fresh result is there before the old one runs out. Each
  check is a task of its own with a fresh nonce
  (`OmnigateControl.Attestation.check/4`).

  It fails closed:

    * a pair is `verified` only after a check passed, and only until
      `checked_at + max_age_s` (`until`). Nothing extends that but another
      pass;
    * a check that fails on the evidence (a bad quote, a wrong nonce, a
      status or measurement the policy refuses) withdraws the pair at once;
    * a check that could not get its inputs (the report, Intel's collateral,
      NVIDIA's verdict) leaves a still-valid result standing until `until`
      and is tried again with a growing pause, at most two minutes.

  Intel's collateral (revocation lists and the lists of patch levels, signed
  by Intel) is fetched once per platform family, shared by all checks, and
  fetched again after a day, so that a revocation or a newly required patch
  level is noticed long before the documents themselves expire.

  Readers (`status/3`, `all/1`, `for_snapshot/4`) never wait for this
  process: the entries are kept in a public ETS table.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{Attestation, ConfigStore, Text}
  alias OmnigateControl.Attestation.Tdx

  @tick_ms 1_000
  @max_parallel 4
  @backoff_s [5, 15, 60, 120]
  @collateral_refresh_s 86_400
  @check_timeout_ms 120_000
  @collateral :omnigate_attestation_collateral
  @counters :omnigate_attestation_counters
  @entries :omnigate_attestation_entries

  @doc """
  Create the tables (verdicts, Intel's collateral, counters). Called once at
  boot, from the application's own process, so that they outlive a restart
  of the manager; a manager started without the application (a test)
  creates what is missing itself.
  """
  def setup do
    for table <- [@collateral, @counters, @entries], :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # ---- Reading -------------------------------------------------------------

  @doc "Every pair being kept, sorted: a list of entries (maps; `OmnigateControl.Attestation.view/2` shows one)."
  def all(server \\ __MODULE__), do: entries(server) |> Map.values() |> Enum.sort_by(&{&1.upstream, &1.model})

  @doc "The entry of one pair, or nil when the config does not ask for it."
  def status(upstream, model, server \\ __MODULE__), do: Map.get(entries(server), {upstream, model})

  @doc """
  What the data-plane snapshot says about a target, or nil when its upstream
  has no attestation setting: `%{verified, max_age_s, tcb, since}`.

  `verified` is true only while the last pass is younger than `max_age_s`.
  The data plane applies the same age to its own contact with this control
  plane, so a snapshot that stopped being refreshed does not stay "verified"
  for ever.
  """
  def for_snapshot(upstream, model, now \\ System.os_time(:second), server \\ __MODULE__) do
    case status(upstream, model, server) do
      nil ->
        nil

      e ->
        ok = verified?(e, now)
        %{verified: ok, max_age_s: e.max_age_s, tcb: if(ok, do: e.evidence.gateway.status), since: if(ok, do: e.verified_since, else: 0)}
    end
  end

  @doc "Is the pair verified right now?"
  def verified?(%{state: :verified, until: until}, now) when is_integer(until), do: now < until
  def verified?(_, _now), do: false

  @doc "Checks run since start, by outcome: `%{ok: n, failed: n, unavailable: n}`."
  def counts do
    for outcome <- [:ok, :failed, :unavailable], into: %{} do
      {outcome, counter(outcome)}
    end
  end

  @doc """
  Check one pair now, with a fresh nonce, and wait for the verdict: the
  entry as it is afterwards, or nil when the config does not ask for the
  pair. Used by the dashboard's "verify again now".
  """
  def verify_now(upstream, model, server \\ __MODULE__), do: GenServer.call(server, {:verify_now, upstream, model}, @check_timeout_ms + 5_000)

  @doc "Look at the config now instead of at the next tick (tests)."
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  # (Keyed by the server's name: a test runs a manager of its own beside
  # the application's.)
  defp entries(server) do
    @entries |> :ets.match({{server, :"$1"}, :"$2"}) |> Map.new(fn [pair, entry] -> {pair, entry} end)
  rescue
    # No table: nothing is being attested (the application is not running).
    ArgumentError -> %{}
  end

  defp counter(outcome) do
    case :ets.whereis(@counters) != :undefined && :ets.lookup(@counters, outcome) do
      [{_, n}] -> n
      _ -> 0
    end
  end

  # ---- Server --------------------------------------------------------------

  @impl true
  def init(opts) do
    setup()
    name = Keyword.get(opts, :name, __MODULE__)
    # Whatever a previous run of this manager left is not a verdict of this one.
    :ets.match_delete(@entries, {{name, :_}, :_})

    state = %{
      name: name,
      entries: %{},
      # task ref => {pair, [waiting callers]}
      running: %{},
      # Passed on to every check, by a test that starts a manager of its
      # own: `:http`, `:collateral`, `:nonce`, `:now`, `:trusted_root_der`.
      # Nothing in the config or the environment reaches these.
      check_opts: Keyword.get(opts, :check_opts, []),
      config: Keyword.get(opts, :config, &ConfigStore.get/0),
      tick?: Keyword.get(opts, :tick, true)
    }

    if state.tick?, do: Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state |> reconcile() |> start_due()}
  end

  def handle_info({ref, {:checked, pair, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, ref, pair, result)}
  end

  # A check that crashed is a check that failed to get an answer.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.running[ref] do
      {pair, _} -> {:noreply, finished(state, ref, pair, {:error, {:report_unavailable, {:crashed, Text.line(inspect(reason), 200)}}})}
      nil -> {:noreply, state}
    end
  end

  # Every call a check makes has a timeout of its own; this is the bound on
  # all of them together.
  def handle_info({:check_timeout, ref, pid}, state) do
    case state.running[ref] do
      {pair, _} ->
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(OmnigateControl.Attestation.TaskSup, pid)
        {:noreply, finished(state, ref, pair, {:error, {:report_unavailable, :timeout}})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state |> reconcile() |> start_due()}

  def handle_call({:verify_now, upstream, model}, from, state) do
    state = reconcile(state)
    pair = {upstream, model}

    case state.entries[pair] do
      nil ->
        {:reply, nil, state}

      entry ->
        case Enum.find(state.running, fn {_ref, {p, _}} -> p == pair end) do
          # One is under way: its verdict is as fresh as a new one would be.
          {ref, {^pair, waiting}} -> {:noreply, %{state | running: Map.put(state.running, ref, {pair, [from | waiting]})}}
          nil -> {:noreply, start_check(state, entry, [from])}
        end
    end
  end

  # ---- Config against table ------------------------------------------------

  defp reconcile(state) do
    wanted =
      try do
        Attestation.wanted(state.config.())
      rescue
        # The config store is restarting: keep what there is.
        _ -> nil
      end

    if wanted == nil do
      state
    else
      now = System.os_time(:second)
      keep = Map.new(wanted, &{{&1.upstream, &1.model}, &1})

      entries =
        Map.new(keep, fn {pair, want} ->
          case state.entries[pair] do
            # Same place and same policy: what was found still answers the question.
            %{base_url: base, setting: setting} = entry when base == want.base_url and setting == want.setting -> {pair, entry}
            _ -> {pair, new_entry(want, now)}
          end
        end)

      for {pair, _} <- state.entries, not Map.has_key?(entries, pair) do
        Logger.info("attestation: #{label(pair)} is no longer routed to; dropped")
      end

      publish(%{state | entries: entries})
    end
  end

  defp new_entry(want, now) do
    %{
      upstream: want.upstream,
      model: want.model,
      base_url: want.base_url,
      setting: want.setting,
      max_age_s: want.setting.max_age_s,
      state: :pending,
      reason: nil,
      reason_code: nil,
      evidence: nil,
      checked_at: nil,
      verified_since: nil,
      until: nil,
      last_attempt_at: nil,
      next_check_at: now,
      failures: 0,
      checks: 0
    }
  end

  defp start_due(state) do
    now = System.os_time(:second)
    busy = MapSet.new(state.running, fn {_ref, {pair, _}} -> pair end)

    state.entries
    |> Enum.filter(fn {pair, e} -> e.next_check_at <= now and not MapSet.member?(busy, pair) end)
    |> Enum.sort_by(fn {_pair, e} -> e.next_check_at end)
    |> Enum.take(max(@max_parallel - map_size(state.running), 0))
    |> Enum.reduce(state, fn {_pair, entry}, acc -> start_check(acc, entry, []) end)
    |> expire(now)
  end

  # A result that ran out without a newer pass is no longer a result.
  defp expire(state, now) do
    expired = for {pair, %{state: :verified, until: until} = e} <- state.entries, until <= now, do: {pair, e}

    if expired == [] do
      state
    else
      entries =
        Enum.reduce(expired, state.entries, fn {pair, e}, acc ->
          Logger.warning(
            "attestation: #{label(pair)} was verified #{now - e.checked_at} s ago and has not been verified again: withdrawn (#{e.reason || "no newer check"})"
          )

          Map.put(acc, pair, %{
            e
            | state: :failed,
              reason: e.reason || "the last verification is older than max_age_s and no newer one succeeded",
              reason_code: e.reason_code || "expired"
          })
        end)

      publish(%{state | entries: entries})
    end
  end

  # ---- One check -----------------------------------------------------------

  defp start_check(state, entry, waiting) do
    pair = {entry.upstream, entry.model}
    opts = Keyword.put_new(state.check_opts, :collateral, &collateral(&1, state.check_opts))
    base_url = entry.base_url
    model = entry.model
    setting = entry.setting

    task =
      Task.Supervisor.async_nolink(OmnigateControl.Attestation.TaskSup, fn ->
        {:checked, pair, Attestation.check(base_url, model, setting, opts)}
      end)

    Process.send_after(self(), {:check_timeout, task.ref, task.pid}, @check_timeout_ms)
    %{state | running: Map.put(state.running, task.ref, {pair, waiting})}
  end

  defp finished(state, ref, pair, result) do
    {{_pair, waiting}, running} = Map.pop(state.running, ref, {pair, []})
    state = %{state | running: running}
    now = System.os_time(:second)

    state =
      case state.entries[pair] do
        # Dropped from the config while the check ran.
        nil -> state
        entry -> publish(%{state | entries: Map.put(state.entries, pair, apply_result(entry, result, now))})
      end

    for from <- waiting, do: GenServer.reply(from, state.entries[pair])
    state
  end

  defp apply_result(entry, {:ok, evidence}, now) do
    count(:ok)

    if entry.state != :verified,
      do:
        Logger.info("attestation: #{label(entry)} verified (TCB #{evidence.gateway.status}, signer #{String.slice(evidence.gateway.signing_address, 0, 16)}…)")

    %{
      entry
      | state: :verified,
        reason: nil,
        reason_code: nil,
        evidence: evidence,
        checked_at: now,
        verified_since: if(entry.state == :verified, do: entry.verified_since, else: now),
        until: now + entry.max_age_s,
        last_attempt_at: now,
        # Half way, so that a fresh pass is there before this one runs out.
        next_check_at: now + max(div(entry.max_age_s, 2), 30),
        failures: 0,
        checks: entry.checks + 1
    }
  end

  defp apply_result(entry, {:error, reason}, now) do
    transient = Attestation.transient?(reason)
    count(if transient, do: :unavailable, else: :failed)
    failures = entry.failures + 1
    pause = Enum.at(@backoff_s, min(failures, length(@backoff_s)) - 1)
    words = Attestation.describe(reason)
    code = Attestation.code(reason)
    still_valid = transient and Attestation.Manager.verified?(entry, now)

    cond do
      still_valid and entry.reason != words ->
        Logger.warning("attestation: #{label(entry)} could not be checked again (#{words}); the last pass stands until it is #{entry.max_age_s} s old")

      not still_valid and (entry.state != :failed or entry.reason != words) ->
        Logger.warning("attestation: #{label(entry)} NOT verified: #{words}. Its targets are not used until it verifies.")

      true ->
        :ok
    end

    entry = %{entry | reason: words, reason_code: code, last_attempt_at: now, next_check_at: now + pause, failures: failures, checks: entry.checks + 1}
    if still_valid, do: entry, else: %{entry | state: :failed}
  end

  # ---- Collateral ----------------------------------------------------------

  # Called inside a check's task. The table is shared by all of them.
  defp collateral(quote, check_opts) do
    now = System.os_time(:second)

    with {:ok, key} <- Tdx.collateral_key(quote) do
      cached =
        case :ets.lookup(@collateral, key) do
          [{_, c, fetched_at}] -> {c, fetched_at}
          [] -> nil
        end

      case cached do
        {c, fetched_at} when now - fetched_at < @collateral_refresh_s ->
          {:ok, c}

        _ ->
          case Tdx.fetch_collateral(quote, Keyword.take(check_opts, [:http])) do
            {:ok, c} ->
              :ets.insert(@collateral, {key, c, now})
              {:ok, c}

            # A day-old copy is still signed by Intel and still within its
            # validity (which `Tdx.verify` checks): better than no check.
            {:error, _} when cached != nil ->
              {:ok, elem(cached, 0)}

            error ->
              error
          end
      end
    end
  end

  # ---- Helpers -------------------------------------------------------------

  defp publish(state) do
    :ets.insert(@entries, for({pair, entry} <- state.entries, do: {{state.name, pair}, entry}))

    for [pair] <- :ets.match(@entries, {{state.name, :"$1"}, :_}), not Map.has_key?(state.entries, pair) do
      :ets.delete(@entries, {state.name, pair})
    end

    state
  end

  defp count(outcome), do: :ets.update_counter(@counters, outcome, 1, {outcome, 0})

  defp label(%{upstream: upstream, model: model}), do: label({upstream, model})
  defp label({upstream, model}), do: "#{Text.line(upstream, 80)}/#{Text.line(model, 120)}"
end
