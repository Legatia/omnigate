defmodule OmnigateControl.Ledger do
  @moduledoc """
  Durable usage ledger.

  Usage events arrive in batches from data planes. A batch is appended to a
  JSONL event log and synced to disk before it is acknowledged, then folded
  into an ETS table of per-key totals. On boot the log is replayed, so spend
  survives restarts.

  Delivery from data planes is at-least-once: a batch is resent when its
  acknowledgement is lost. Every event carries a unique `id`, and an event
  whose id was already recorded is skipped, so resends never double-bill.

  The set of seen ids lives in memory and would grow with the log, so
  `prune_ids/1` (driven by `retention.ledger_ids_days`) drops the ids of whole
  UTC days that ended before a cutoff (`OmnigateControl.Ledger.Ids` explains
  the layout: one table and one small file per day, outside the snapshot). An
  id only matters while a data plane might still resend its event. The trade
  is explicit: an event resent after its id was pruned is counted a second
  time. Totals and the log file are never touched by pruning.

  ## While it is starting

  The tables other processes read (`totals/1`, `spend/1`, ...) get their
  public names only once the snapshot is loaded and the later events are
  replayed. Until then a read raises instead of answering from a half-filled
  table: "this key has spent nothing" must never be an artefact of a restart.
  Callers that decide something from spend check `ready?/0` first or let the
  error turn into a refusal.

  ## Tokens and cost

  A text event counts three kinds of input: `input_tokens` (uncached),
  `cached_input_tokens` (read from the provider's prompt cache) and
  `cache_write_input_tokens` (written to it), plus `output_tokens`. Each is
  priced separately; the two cache prices default to the input price, so a
  config that does not mention them bills exactly as before. An event marked
  `"cached": true` was answered from the data plane's own response cache: it
  counts as a request and costs nothing.

  ## Budget periods

  Besides the per-key totals, spend is kept per key per UTC month and per UTC
  day (by the event's own time), so a key with a monthly or daily budget can
  be checked cheaply and unblocks by itself when the period turns. These rows
  are rebuilt on replay like everything else; rows of past periods are
  dropped from memory after a while (the log file keeps the events).

  ## Snapshots, segments and rotation

  Boot does not replay the whole history. The process writes a snapshot of
  its tables every so many events, every few minutes, after a rotation and at
  a clean stop; boot loads the newest valid one and replays only the events
  written after it. The log is split into segments (by size, and at the turn
  of the UTC day), and `retention.ledger_days` deletes segments older than
  that. Their contribution stays in the snapshots, so lifetime and period
  totals are unaffected. See `OmnigateControl.Ledger.Files` for the files and
  for why a crash at any step loses nothing.

  The consequence of deleting segments: the snapshots then hold the only copy
  of those totals. Two generations are kept, and a segment is deleted only
  once both cover it. If both were ever lost, boot would rebuild from the
  segments that remain and say so loudly.

  Next step: replicate events across control-plane nodes so budgets are
  enforced cluster-wide.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{Counters, Text}
  alias OmnigateControl.Ledger.{Files, Ids}

  @table :omnigate_ledger_totals
  @prune_periods_ms 3_600_000
  @seen :omnigate_ledger_seen
  @recent 50

  # `name: nil` and `tables: {totals, seen}` exist for tests, which run extra
  # ledgers on scratch directories next to the application's own.
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Write a snapshot now. Returns `:ok` or `{:error, reason}`."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot, 120_000)

  @doc "Seal the active segment and start a new one (then snapshot)."
  def rotate(server \\ __MODULE__), do: GenServer.call(server, :rotate, 120_000)

  @doc """
  Delete sealed segments whose last event is older than `cutoff_ms`, as far as
  both snapshot generations cover them. Returns how many were deleted.
  """
  def prune_segments(cutoff_ms, server \\ __MODULE__) when is_integer(cutoff_ms), do: GenServer.call(server, {:prune_segments, cutoff_ms}, 120_000)

  @doc "For readiness checks: `%{ready, writable, segment, offset, events_since_snapshot, snapshot_ms}`, or `{:error, reason}`."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 2_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  def dump(server), do: GenServer.call(server, :dump, 120_000)

  @doc """
  Record a batch of usage events from a data plane.

  Returns `{:ok, %{accepted: n, duplicates: n, invalid: n}}` once every
  accepted event is on disk.
  """
  def record_batch(events) when is_list(events), do: GenServer.call(__MODULE__, {:record_batch, events, :text})

  @doc """
  Record the cost of one finished media job. The event carries its own
  `cost_usd` (jobs are priced per output, second or character, not per
  token) and uses the job id as its id, so recording a job twice is a no-op.
  """
  def record_media(%{"id" => _} = event), do: GenServer.call(__MODULE__, {:record_batch, [event], :media})

  @doc """
  Record credit added to a key (a top-up or a bonus), so that the events
  feed is a complete statement: usage and credit in one order. The event is
  `%{"id", "key_sha256", "amount_usd", "source", "reference", "eligible",
  "budget_usd"}`; it counts as no request and costs nothing.
  """
  def record_credit(%{"id" => id, "key_sha256" => key} = event) when is_binary(id) and is_binary(key) do
    GenServer.call(__MODULE__, {:record_batch, [Map.put(event, "status", 200)], :credit})
  end

  @doc """
  Forget the dedup ids of every UTC day that ended at or before `cutoff_ms`
  (unix milliseconds). Returns how many ids were dropped.
  """
  def prune_ids(cutoff_ms, server \\ __MODULE__) when is_integer(cutoff_ms), do: GenServer.call(server, {:prune_ids, cutoff_ms}, 60_000)

  @doc "True once the tables are loaded and published. False while the ledger is starting, restarting or down."
  def ready?, do: :ets.whereis(@table) != :undefined

  @doc "Counts for monitoring: events recorded since the log began, and dedup ids currently held."
  def stats do
    %{events: grand_totals().requests, dedup_ids: Ids.count(@seen)}
  end

  @doc """
  Totals over every key.

  Added up in key order, not in the order the table happens to hold its
  rows: floating-point sums depend on the order of their terms, and a table
  rebuilt from a snapshot holds the same rows in a different order. This way
  the grand total after a restart is the grand total from before it, to the
  last digit.
  """
  def grand_totals do
    @table
    |> :ets.select([{{:"$1", :"$2"}, [{:is_binary, :"$1"}], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
    |> Enum.reduce(empty_totals(), fn {_key, totals}, sum -> Map.merge(sum, totals, fn _field, a, b -> a + b end) end)
  end

  @doc "Totals over every key for one UTC day, given as `\"YYYY-MM-DD\"` (default: today)."
  def day_totals(day \\ Date.utc_today() |> Date.to_iso8601()) do
    case :ets.lookup(@table, {:day, day}) do
      [{_, totals}] -> totals
      [] -> empty_totals()
    end
  end

  @doc "Totals for one key hash."
  def totals(key_sha256) do
    case :ets.lookup(@table, key_sha256) do
      [{_, totals}] -> totals
      [] -> empty_totals()
    end
  end

  @doc "Spend in USD for one key hash."
  def spend(key_sha256), do: totals(key_sha256).cost_usd

  @doc """
  What one key hash has burned in credit beyond what the provider cost: the
  sum over its events of `credits_usd - cost_usd`. Zero for every key billed
  at the provider cost (a burn multiplier of 1), so cost plus this is what a
  prepaid key has used of its credit. See `OmnigateControl.Credits`.
  """
  def credits_extra(key_sha256) do
    case :ets.lookup(@table, {:credits_extra, key_sha256}) do
      [{_, extra}] -> extra
      [] -> 0.0
    end
  end

  @doc """
  Spend in USD for one key hash in the current budget period: `"monthly"`
  (this UTC month), `"daily"` (this UTC day), anything else the whole ledger.
  """
  def period_spend(key_sha256, period, now \\ DateTime.utc_now())

  def period_spend(key_sha256, period, now) when period in ["monthly", "daily"] do
    case :ets.lookup(@table, {:period, key_sha256, period_id(period, now)}) do
      [{_, cost}] -> cost
      [] -> 0.0
    end
  end

  def period_spend(key_sha256, _total, _now), do: spend(key_sha256)

  @doc "The id of the period `now` falls in: `\"2026-11\"` for monthly, `\"2026-11-10\"` for daily."
  def period_id("monthly", %DateTime{} = now), do: now |> DateTime.to_iso8601() |> binary_part(0, 7)
  def period_id("daily", %DateTime{} = now), do: now |> DateTime.to_iso8601() |> binary_part(0, 10)

  @doc "When the period `now` falls in ends (the next UTC month or day), or nil for a total budget."
  def period_resets_at(period, now \\ DateTime.utc_now())

  def period_resets_at("monthly", %DateTime{year: y, month: m}) do
    {y, m} = if m == 12, do: {y + 1, 1}, else: {y, m + 1}
    DateTime.new!(Date.new!(y, m, 1), ~T[00:00:00], "Etc/UTC")
  end

  def period_resets_at("daily", %DateTime{} = now) do
    DateTime.new!(now |> DateTime.to_date() |> Date.add(1), ~T[00:00:00], "Etc/UTC")
  end

  def period_resets_at(_total, _now), do: nil

  @doc "Most recent events, newest first."
  def recent, do: GenServer.call(__MODULE__, :recent)

  @events_scan_bytes 4 * 1_048_576

  @doc """
  One page of recorded events, oldest first, for readers outside (the admin
  API's events feed): see `OmnigateControl.Ledger.Files.read_events/6`.
  `cursor` is `nil` or a `{segment, offset}` position from an earlier page;
  `keep` picks the events wanted. Read inside the ledger process, so a page
  never sees half a batch; at most #{div(@events_scan_bytes, 1_048_576)} MiB are read per call.
  """
  def events(cursor, limit, keep \\ fn _ -> true end, server \\ __MODULE__) when is_integer(limit) and limit > 0 do
    GenServer.call(server, {:events, cursor, limit, keep}, 120_000)
  end

  @doc "Cost of a usage event given USD-per-1M-token prices."
  def cost(input_tokens, output_tokens, {price_in, price_out}) do
    (input_tokens * price_in + output_tokens * price_out) / 1_000_000
  end

  @doc """
  Cost in USD of token counts `%{input, cached_input, cache_write, output}`
  at prices per 1M tokens `%{in, cached_in, cache_write, out}`.
  """
  def cost(tokens, prices) when is_map(tokens) and is_map(prices) do
    (tokens.input * prices.in + tokens.cached_input * prices.cached_in + tokens.cache_write * prices.cache_write +
       tokens.output * prices.out) / 1_000_000
  end

  @doc "True when an event has the fields the ledger needs."
  def valid?(%{"key_sha256" => key, "status" => status} = event)
      when is_binary(key) and is_integer(status) do
    tokens_ok?(event["input_tokens"]) and tokens_ok?(event["output_tokens"]) and
      tokens_ok?(event["cached_input_tokens"]) and tokens_ok?(event["cache_write_input_tokens"]) and
      (is_nil(event["id"]) or is_binary(event["id"]))
  end

  def valid?(_), do: false

  # More tokens than any request has: a count beyond this is a broken
  # reporter, and arithmetic on it would overflow a float.
  @max_tokens 1_000_000_000_000

  defp tokens_ok?(nil), do: true
  defp tokens_ok?(n), do: is_integer(n) and n >= 0 and n <= @max_tokens

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    {table, seen} = Keyword.get(opts, :tables, {@table, @seen})
    Process.put(:ledger_clock, Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end))
    Process.flag(:trap_exit, true)

    # Both tables are filled under a private name and only get the name
    # readers use when everything is loaded (see "While it is starting").
    loading = fn name -> :"#{name}_loading" end
    :ets.new(loading.(table), [:named_table, :set, :protected, read_concurrency: true])
    # Day -> the table holding that day's event ids.
    :ets.new(loading.(seen), [:named_table, :set, :protected])
    # Table ids stay valid across the rename.
    totals_tid = :ets.whereis(loading.(table))
    registry = :ets.whereis(loading.(seen))
    Process.put(:ledger_tables, {totals_tid, registry})

    offset = Files.repair_active(path)
    started = System.monotonic_time(:millisecond)

    {covered, recent, generations, ids, migrated} =
      case Files.load_snapshot(path) do
        {:ok, snapshot, which} ->
          :ets.insert(totals_tid, snapshot.totals)

          {ids, migrated} =
            case snapshot do
              %{version: 2, ids: sizes} -> {Ids.load(path, registry, sizes), false}
              # From before ids had their own files: write them out, by the day they were recorded.
              %{seen: seen_rows} -> {migrate_ids(Ids.reset(path, registry), seen_rows), true}
            end

          if which == :prev do
            Logger.warning("ledger: using the previous snapshot; the newest one was unusable")
            # Remove the bad one, or the next snapshot would move it over the
            # good spare we are running from.
            File.rm(Files.snapshot_path(path))
          end

          {seq, _} = snapshot.covered
          # The snapshot just read is the only one vouched for. Segments are
          # deleted only when two validated generations cover them: this one
          # and the next one this run writes.
          {snapshot.covered, Map.get(snapshot, :recent, []), {seq, nil}, ids, migrated}

        :none ->
          warn_if_history_missing(path)
          # Every event still on disk is replayed and brings its id back.
          {nil, [], {nil, nil}, Ids.reset(path, registry), false}
      end

    today = day_of(now_ms())

    # The ids loaded so far are exactly those of the events the snapshot
    # counted. An event after the snapshot whose id is among them has been
    # counted already (a snapshot and its offset that disagree, a batch
    # written twice): it is skipped rather than counted again.
    {replayed, skipped, recent, ids} =
      Enum.reduce(Files.tail(path, covered), {0, 0, recent, ids}, fn {file, from}, acc ->
        Files.fold(file, from, acc, fn event, {n, skipped, recent, ids} ->
          key = is_binary(event["id"]) && Ids.key(event["id"])

          if key && Ids.member?(ids, key) do
            {n, skipped + 1, recent, ids}
          else
            apply_event(event)
            ids = if key, do: Ids.add(ids, [key], received_day(event, today)), else: ids
            {n + 1, skipped, Enum.take([event | recent], @recent), ids}
          end
        end)
      end)

    if skipped > 0, do: Logger.warning("ledger: skipped #{skipped} events after the snapshot that it had already counted")
    took = System.monotonic_time(:millisecond) - started

    if replayed > 0 or covered do
      from = if covered, do: "a snapshot plus #{replayed} later events", else: "#{replayed} events"
      Logger.info("ledger ready in #{took} ms from #{from} (#{path})")
    end

    file = File.open!(path, [:append, :binary])
    {current, prev} = generations

    state = %{
      path: path,
      file: file,
      ids: ids,
      recent: recent,
      segment: Files.active_seq(path),
      offset: offset,
      # UTC day the active segment's first event was written, for daily sealing.
      segment_day: if(offset > 0, do: file_day(path), else: nil),
      since_snapshot: replayed,
      snapshot_ms: nil,
      # Segment numbers the two snapshot generations cover up to (nil = none).
      covered: current,
      covered_prev: prev,
      # How a segment is sealed; replaced only by tests that make it fail.
      seal: Keyword.get(opts, :seal, &Files.seal/1),
      snapshot_every: Keyword.get(opts, :snapshot_every, env(:ledger_snapshot_every, 50_000)),
      segment_bytes: Keyword.get(opts, :segment_bytes, env(:ledger_segment_bytes, 64 * 1024 * 1024)),
      tick_ms: Keyword.get(opts, :tick_ms, env(:ledger_snapshot_interval_ms, 300_000))
    }

    # A boot that had to replay leaves a snapshot behind, so the next one does not.
    state = if replayed > 0 or is_nil(covered) or migrated, do: take_snapshot(state), else: state

    # Loaded: from here on readers may see the tables.
    :ets.rename(totals_tid, table)
    :ets.rename(registry, seen)

    Process.send_after(self(), :prune_periods, @prune_periods_ms)
    Process.send_after(self(), :tick, state.tick_ms)
    {:ok, state}
  end

  defp env(key, default), do: Application.get_env(:omnigate_control, key, default)

  defp now_ms, do: Process.get(:ledger_clock).()
  defp day_of(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

  # The UTC day an event was recorded on, from the stamp it got then.
  defp received_day(event, default) do
    case event["received_at"] do
      <<day::binary-size(10), "T", _::binary>> -> day
      _ -> default
    end
  end

  # Ids from a version 1 snapshot, `{id, recorded_ms}`, into per-day files.
  defp migrate_ids(ids, rows) do
    rows
    |> Enum.group_by(fn {_id, ms} -> day_of(ms) end, fn {id, _ms} -> Ids.key(id) end)
    |> Enum.reduce(ids, fn {day, keys}, ids -> Ids.add(ids, keys, day) end)
  end

  # Segments are numbered from 1. If the oldest one left is not number 1 and no
  # snapshot vouches for the deleted ones, their totals are gone.
  defp warn_if_history_missing(path) do
    case Files.sealed(path) do
      [{first, _} | _] when first > 1 ->
        Logger.error(
          "ledger: no usable snapshot, and segments before #{first} were deleted by retention. " <>
            "Totals are being rebuilt from the remaining segments only; spend recorded before them is lost."
        )

      _ ->
        :ok
    end
  end

  defp file_day(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: seconds}} -> seconds |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()
      _ -> nil
    end
  end

  # Only the current period is ever read; the one before it is kept as a
  # margin for clocks and late events. Older rows would otherwise pile up at
  # one per key per day.
  @impl true
  def handle_info(:prune_periods, state) do
    prune_periods(DateTime.utc_now())
    Process.send_after(self(), :prune_periods, @prune_periods_ms)
    {:noreply, state}
  end

  # Periodic: seal a segment that belongs to an earlier UTC day, and snapshot
  # if anything was recorded since the last one.
  def handle_info(:tick, state) do
    today = Date.utc_today() |> Date.to_iso8601()

    state =
      cond do
        state.offset > 0 and state.segment_day not in [nil, today] -> state |> seal() |> take_snapshot()
        state.since_snapshot > 0 -> take_snapshot(state)
        true -> state
      end

    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A clean stop leaves a snapshot, so the next boot replays nothing. Only a
  # clean one: after a crash the tables may hold a batch this state never
  # heard of, and a snapshot of that with the old offset would make the next
  # boot count the batch a second time. A crashed ledger is rebuilt from the
  # last good snapshot and the events after it.
  @impl true
  def terminate(reason, state) do
    clean = reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)
    if clean and state.since_snapshot > 0, do: take_snapshot(state)
    File.close(state.file)
    Ids.close(state.ids)
    :ok
  end

  @doc "Drop the per-period spend rows of periods long past. Runs hourly by itself."
  def prune_period_rows(now \\ DateTime.utc_now()), do: GenServer.call(__MODULE__, {:prune_periods, now})

  # Runs in the ledger process: the table is protected.
  defp prune_periods(now) do
    keep_month = now |> DateTime.add(-32 * 86_400, :second) |> then(&period_id("monthly", &1))
    keep_day = now |> DateTime.add(-2 * 86_400, :second) |> then(&period_id("daily", &1))

    for {{:period, _key, id} = row, _cost} <- :ets.tab2list(tab()),
        (byte_size(id) == 7 and id < keep_month) or (byte_size(id) == 10 and id < keep_day) do
      :ets.delete(tab(), row)
    end

    :ok
  end

  @impl true
  def handle_call({:record_batch, events, kind}, _from, state) do
    {accepted, counts} = classify(events, kind, state.ids)

    state =
      if accepted != [] do
        # Write-ahead: the whole batch is on disk before totals change or we ack.
        bytes = IO.iodata_to_binary(Enum.map(accepted, fn {_event, line} -> [line, ?\n] end))
        accepted = Enum.map(accepted, fn {event, _line} -> event end)
        :ok = IO.binwrite(state.file, bytes)
        :ok = :file.datasync(state.file)
        keys = for %{"id" => id} <- accepted, is_binary(id), do: Ids.key(id)
        ids = Ids.add(state.ids, keys, day_of(now_ms()))
        Enum.each(accepted, &apply_event/1)

        %{
          state
          | ids: ids,
            offset: state.offset + byte_size(bytes),
            since_snapshot: state.since_snapshot + length(accepted),
            segment_day: state.segment_day || Date.utc_today() |> Date.to_iso8601(),
            recent: Enum.take(Enum.reverse(accepted) ++ state.recent, @recent)
        }
      else
        state
      end

    state =
      cond do
        state.offset >= state.segment_bytes -> state |> seal() |> take_snapshot()
        state.since_snapshot >= state.snapshot_every -> take_snapshot(state)
        true -> state
      end

    {:reply, {:ok, counts}, state}
  end

  # Requests and jobs; credit added to a key is not one.
  def handle_call(:recent, _from, state), do: {:reply, Enum.reject(state.recent, &(&1["kind"] == "credit")), state}

  def handle_call({:events, cursor, limit, keep}, _from, state) do
    {:reply, Files.read_events(state.path, cursor, {state.segment, state.offset}, limit, @events_scan_bytes, keep), state}
  end

  def handle_call({:prune_periods, now}, _from, state), do: {:reply, prune_periods(now), state}

  # Whole days only: a day goes once its last millisecond is at or before the
  # cutoff, so every id is kept for at least the configured window.
  #
  # A snapshot follows at once. The replay after a restart skips events whose
  # ids it already holds; an event that was resent after its id was forgotten
  # (and so, by the documented trade, counted again) must then be covered by
  # a snapshot, or the next boot would see its first copy's id come back from
  # the replay and count the second copy differently from how this run did.
  def handle_call({:prune_ids, cutoff_ms}, _from, state) do
    {ids, dropped} = Ids.drop_before(state.ids, day_of(cutoff_ms))
    state = %{state | ids: ids}
    {:reply, dropped, if(dropped > 0, do: take_snapshot(state), else: state)}
  end

  def handle_call(:snapshot, _from, state) do
    state = take_snapshot(state)
    {:reply, if(state.since_snapshot == 0, do: :ok, else: {:error, :snapshot_failed}), state}
  end

  def handle_call(:rotate, _from, state) do
    state = if state.offset > 0, do: state |> seal() |> take_snapshot(), else: state
    {:reply, {:ok, state.segment}, state}
  end

  # A segment goes only when BOTH snapshot generations cover it: then either
  # one alone still reproduces the totals it contributed.
  def handle_call({:prune_segments, cutoff_ms}, _from, state) do
    # Two generations must cover a segment, and after a restart only one is
    # vouched for: the snapshot this process booted from. On a busy system
    # the next snapshot comes by itself; on a quiet one nothing is recorded,
    # no snapshot is written, and due segments would never go. So write one
    # now. It is built from the state the validated snapshot produced, and
    # the validated one becomes the spare: two generations, both good.
    quiet_restart = is_integer(state.covered) and is_nil(state.covered_prev)
    state = if state.since_snapshot > 0 or quiet_restart, do: take_snapshot(state), else: state

    deleted =
      case {state.covered, state.covered_prev} do
        {current, prev} when is_integer(current) and is_integer(prev) -> Files.delete_segments(state.path, min(current, prev), cutoff_ms)
        _ -> 0
      end

    {:reply, deleted, state}
  end

  def handle_call(:status, _from, state) do
    writable = match?({:ok, %{access: access}} when access in [:read_write, :write], File.stat(state.path))

    {:reply,
     %{
       ready: true,
       writable: writable,
       segment: state.segment,
       offset: state.offset,
       events_since_snapshot: state.since_snapshot,
       snapshot_ms: state.snapshot_ms
     }, state}
  end

  def handle_call(:dump, _from, state) do
    {:reply, %{totals: Enum.sort(:ets.tab2list(tab())), ids: Ids.all(state.ids)}, state}
  end

  # Close the active file under its number and start the next one.
  #
  # Never fatal, like a snapshot: by the time a seal is due the batch that
  # filled the segment is already on disk and in the totals. Failing here
  # (a full disk, a permission) must not undo that or take the process down
  # with totals its state does not describe; the segment simply stays active
  # and the seal is tried again after the next batch.
  defp seal(state) do
    File.close(state.file)

    sealed =
      try do
        {:ok, state.seal.(state.path)}
      rescue
        e -> {:error, e}
      end

    case sealed do
      {:ok, segment} ->
        Logger.info("ledger: sealed segment #{segment - 1} (#{state.offset} bytes)")
        %{state | file: File.open!(state.path, [:append, :binary]), segment: segment, offset: 0, segment_day: nil}

      {:error, e} ->
        Logger.error("ledger: sealing segment #{state.segment} failed, will try again: #{Text.line(Exception.message(e))}")
        # Whatever step failed, the active file is (or becomes) the one the
        # numbering says it is, and its size is where the next write goes.
        file = File.open!(state.path, [:append, :binary])
        segment = Files.active_seq(state.path)
        offset = File.stat!(state.path).size
        %{state | file: file, segment: segment, offset: offset, segment_day: if(offset > 0, do: state.segment_day, else: nil)}
    end
  end

  # Never fatal: a snapshot that cannot be written costs boot time later, and
  # recording usage must go on.
  #
  # A snapshot holds the totals, not the event ids: its size follows the
  # number of keys, not the number of requests, so writing it does not stall
  # recording. The ids are in their own files; the snapshot only notes how
  # long each one is, after making sure those bytes are on disk.
  defp take_snapshot(state) do
    ids = Ids.sync(state.ids)

    snapshot = %{
      version: 2,
      covered: {state.segment, state.offset},
      totals: :ets.tab2list(tab()),
      ids: Ids.sizes(ids),
      recent: state.recent,
      taken_ms: System.os_time(:millisecond)
    }

    Files.write_snapshot(state.path, snapshot)
    %{state | since_snapshot: 0, snapshot_ms: snapshot.taken_ms, covered: state.segment, covered_prev: state.covered}
  rescue
    e ->
      Logger.error("ledger: snapshot failed: #{Text.line(Exception.message(e))}")
      state
  end

  defp tab, do: Process.get(:ledger_tables) |> elem(0)

  # Splits a batch into `{event, json_line}` pairs to record, in order, plus
  # counts. An event that cannot be recorded (missing fields, wrong types,
  # text that is not valid UTF-8 and so cannot be written as JSON) is counted
  # as invalid, reported in the log and in a metric, and never takes the
  # process down.
  defp classify(events, kind, ids) do
    {accepted, _batch_ids, counts} =
      Enum.reduce(events, {[], MapSet.new(), %{accepted: 0, duplicates: 0, invalid: 0}}, fn event, {acc, batch, counts} ->
        key = is_map(event) && is_binary(event["id"]) && Ids.key(event["id"])

        cond do
          not valid?(event) ->
            {acc, batch, %{counts | invalid: counts.invalid + 1}}

          key && (MapSet.member?(batch, key) or Ids.member?(ids, key)) ->
            {acc, batch, %{counts | duplicates: counts.duplicates + 1}}

          true ->
            case encode(enrich(event, kind)) do
              {:ok, enriched, line} ->
                batch = if key, do: MapSet.put(batch, key), else: batch
                {[{enriched, line} | acc], batch, %{counts | accepted: counts.accepted + 1}}

              :error ->
                {acc, batch, %{counts | invalid: counts.invalid + 1}}
            end
        end
      end)

    if counts.invalid > 0 do
      Counters.bump(:ledger_invalid_events, counts.invalid)
      Logger.warning("ledger: dropped #{counts.invalid} of #{length(events)} usage events in a batch as invalid (missing or mistyped fields)")
    end

    {Enum.reverse(accepted), counts}
  end

  defp encode(event) do
    {:ok, event, JSON.encode!(event)}
  rescue
    _ ->
      # Something in it is not valid UTF-8. Usage must not be lost over a
      # label, so the strings are repaired and the event is kept.
      try do
        clean = Text.clean(event)
        {:ok, clean, JSON.encode!(clean)}
      rescue
        _ -> :error
      end
  end

  @doc """
  A caller's label for a request (`x-omnigate-tag`) as the ledger keeps it:
  the text itself when it is 1 to 64 letters, digits, `.`, `_`, `:` or `-`,
  else nil. The data plane refuses anything else before it gets here; this
  is the same rule for whatever reaches the ledger another way.
  """
  def tag(text) when is_binary(text), do: if(text =~ ~r/\A[A-Za-z0-9._:-]{1,64}\z/, do: text)
  def tag(_), do: nil

  # An event with its tag in that shape, or without the field.
  defp tagged(event) do
    case tag(event["tag"]) do
      nil -> Map.delete(event, "tag")
      _ -> event
    end
  end

  # Credit added to a key: only the fields a statement needs.
  defp enrich(event, :credit) do
    amount = if is_number(event["amount_usd"]) and event["amount_usd"] >= 0 and event["amount_usd"] <= 1.0e12, do: event["amount_usd"] * 1.0, else: 0.0

    event
    |> Map.take(["id", "key_sha256", "status", "source", "reference", "budget_usd", "ts_ms"])
    |> Map.merge(%{"kind" => "credit", "amount_usd" => amount, "eligible" => event["eligible"] == true, "cost_usd" => 0.0})
    |> stamp()
  end

  # Media job events are priced by the job runner; only timestamps are added.
  defp enrich(event, :media) do
    cost = if is_number(event["cost_usd"]) and event["cost_usd"] >= 0 and event["cost_usd"] <= 1.0e12, do: event["cost_usd"] * 1.0, else: 0.0

    event
    |> tagged()
    |> Map.delete("credits_usd")
    |> Map.merge(%{"kind" => "media", "cost_usd" => cost})
    |> burn()
    |> stamp()
  end

  defp enrich(usage, :text) do
    # Only the control plane may mark an event as media, or say what it burns.
    usage = usage |> Map.delete("kind") |> Map.delete("credits_usd")

    # The caller's label (`x-omnigate-tag`): kept only in the shape the data
    # plane lets through, whoever sent the event.
    usage = tagged(usage)

    # What a data plane adds for an answer's receipt is kept by
    # `OmnigateControl.Receipts`, not in the usage history.
    usage = Map.delete(usage, "receipt")

    tokens = %{
      input: usage["input_tokens"] || 0,
      cached_input: usage["cached_input_tokens"] || 0,
      cache_write: usage["cache_write_input_tokens"] || 0,
      output: usage["output_tokens"] || 0
    }

    cost =
      cond do
        # Served from the data plane's response cache: no provider was paid.
        usage["cached"] == true -> 0.0
        is_nil(usage["upstream"]) -> 0.0
        true -> cost(tokens, prices(usage))
      end

    usage |> Map.put("cost_usd", cost) |> burn() |> stamp()
  end

  # What the event burns of a prepaid key's credit, when that is not simply
  # its cost (`OmnigateControl.Credits`): the provider cost times the key's
  # burn multiplier, written next to the cost. At a multiplier of 1 the event
  # is exactly what it was before credit existed.
  defp burn(%{"cost_usd" => cost, "key_sha256" => key} = event) when is_number(cost) and cost > 0 do
    case OmnigateControl.Credits.multiplier_for_hash(key) do
      1.0 -> event
      multiplier -> Map.put(event, "credits_usd", cost * multiplier)
    end
  end

  defp burn(event), do: event

  # An event for a route or target the config does not have is recorded at
  # no cost: there is no price to apply. That is how real spend goes missing
  # from a budget (a route renamed while data planes still use the old
  # snapshot, a typo in a target), so it is counted in a metric and logged
  # once per (route, upstream, model).
  defp prices(usage) do
    triple = {usage["route_model"], usage["upstream"], usage["target_model"]}

    case OmnigateControl.ConfigStore.find_prices(usage["route_model"], usage["upstream"], usage["target_model"]) do
      nil ->
        Counters.bump(:ledger_unpriced_events, 1)
        warned = Process.get(:ledger_unpriced_warned, MapSet.new())

        if not MapSet.member?(warned, triple) and MapSet.size(warned) < 1_000 do
          Process.put(:ledger_unpriced_warned, MapSet.put(warned, triple))

          Logger.warning(
            "ledger: usage for route #{Text.line(triple |> elem(0), 80)} via #{Text.line(triple |> elem(1), 80)}/#{Text.line(triple |> elem(2), 80)} " <>
              "has no price in the config and is recorded at $0 (logged once per route and target; see omnigate_ledger_unpriced_events_total)"
          )
        end

        %{in: 0.0, cached_in: 0.0, cache_write: 0.0, out: 0.0}

      prices ->
        prices
    end
  end

  # `ts` is when the request finished on the data plane, not when the event
  # reached us: events can arrive late after an outage.
  defp stamp(event) do
    now = DateTime.from_unix!(now_ms(), :millisecond)

    ts =
      case event["ts_ms"] do
        # A time no calendar has (a huge or negative number) is not worth a crash.
        ms when is_integer(ms) and ms >= 0 and ms < 253_402_300_800_000 -> DateTime.from_unix!(ms, :millisecond)
        _ -> now
      end

    Map.merge(event, %{
      "ts" => DateTime.to_iso8601(ts),
      "received_at" => DateTime.to_iso8601(now)
    })
  end

  # Credit added to a key changes no usage total (the key store holds it).
  defp apply_event(%{"kind" => "credit"}), do: :ok

  defp apply_event(event) do
    add(event["key_sha256"], event)

    # What a prepaid key burned beyond the provider cost, per key hash.
    case event["credits_usd"] do
      credits when is_number(credits) -> add_period({:credits_extra, event["key_sha256"]}, credits - (event["cost_usd"] || 0.0))
      _ -> :ok
    end

    # One extra row per UTC day (of the event's own time), for "today" figures,
    # and the key's spend in that month and that day, for budget periods.
    case event["ts"] do
      <<month::binary-size(7), _dash, _d::binary-size(2), _rest::binary>> = ts ->
        day = binary_part(ts, 0, 10)
        add({:day, day}, event)
        cost = event["cost_usd"] || 0.0
        add_period({:period, event["key_sha256"], month}, cost)
        add_period({:period, event["key_sha256"], day}, cost)

      _ ->
        :ok
    end
  end

  defp add_period(row, cost) do
    current =
      case :ets.lookup(tab(), row) do
        [{_, c}] -> c
        [] -> 0.0
      end

    :ets.insert(tab(), {row, current + cost})
  end

  defp add(row, event) do
    t =
      case :ets.lookup(tab(), row) do
        [{_, totals}] -> totals
        [] -> empty_totals()
      end

    :ets.insert(
      tab(),
      {row,
       %{
         t
         | requests: t.requests + 1,
           errors: t.errors + if(event["status"] >= 400, do: 1, else: 0),
           input_tokens: t.input_tokens + (event["input_tokens"] || 0),
           cached_input_tokens: t.cached_input_tokens + (event["cached_input_tokens"] || 0),
           cache_write_input_tokens: t.cache_write_input_tokens + (event["cache_write_input_tokens"] || 0),
           output_tokens: t.output_tokens + (event["output_tokens"] || 0),
           cached_responses: t.cached_responses + if(event["cached"] == true, do: 1, else: 0),
           jobs: t.jobs + if(event["kind"] == "media", do: 1, else: 0),
           cost_usd: t.cost_usd + (event["cost_usd"] || 0.0)
       }}
    )
  end

  defp empty_totals do
    %{
      requests: 0,
      errors: 0,
      input_tokens: 0,
      cached_input_tokens: 0,
      cache_write_input_tokens: 0,
      output_tokens: 0,
      cached_responses: 0,
      jobs: 0,
      cost_usd: 0.0
    }
  end
end
