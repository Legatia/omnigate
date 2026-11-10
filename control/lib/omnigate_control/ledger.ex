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
  `prune_ids/1` (driven by `retention.ledger_ids_days`) drops ids recorded
  before a cutoff. An id only matters while a data plane might still resend
  its event, which is minutes to hours. The trade is explicit: an event resent
  after its id was pruned is counted a second time. Totals and the log file
  are never touched by pruning.

  Next step: replicate events across control-plane nodes so budgets are
  enforced cluster-wide.
  """
  use GenServer
  require Logger

  @table :omnigate_ledger_totals
  @seen :omnigate_ledger_seen
  @recent 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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

  @doc "Forget dedup ids recorded before `cutoff_ms` (unix milliseconds). Returns how many were dropped."
  def prune_ids(cutoff_ms) when is_integer(cutoff_ms), do: GenServer.call(__MODULE__, {:prune_ids, cutoff_ms}, 60_000)

  @doc "Counts for monitoring: events recorded since the log began, and dedup ids currently held."
  def stats do
    %{events: grand_totals().requests, dedup_ids: :ets.info(@seen, :size)}
  end

  @doc "Totals over every key."
  def grand_totals do
    :ets.foldl(
      fn
        {key, totals}, sum when is_binary(key) -> Map.merge(sum, totals, fn _field, a, b -> a + b end)
        _day_row, sum -> sum
      end,
      empty_totals(),
      @table
    )
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

  @doc "Most recent events, newest first."
  def recent, do: GenServer.call(__MODULE__, :recent)

  @doc "Cost of a usage event given USD-per-1M-token prices."
  def cost(input_tokens, output_tokens, {price_in, price_out}) do
    (input_tokens * price_in + output_tokens * price_out) / 1_000_000
  end

  @doc "True when an event has the fields the ledger needs."
  def valid?(%{"key_sha256" => key, "status" => status} = event)
      when is_binary(key) and is_integer(status) do
    tokens_ok?(event["input_tokens"]) and tokens_ok?(event["output_tokens"]) and
      (is_nil(event["id"]) or is_binary(event["id"]))
  end

  def valid?(_), do: false

  defp tokens_ok?(nil), do: true
  defp tokens_ok?(n), do: is_integer(n) and n >= 0

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@seen, [:named_table, :set, :protected])

    replayed = replay(path)
    if replayed > 0, do: Logger.info("ledger replayed #{replayed} events from #{path}")

    file = File.open!(path, [:append, :binary])
    {:ok, %{file: file, recent: []}}
  end

  @impl true
  def handle_call({:record_batch, events, kind}, _from, state) do
    {accepted, counts} = classify(events, kind)

    if accepted != [] do
      # Write-ahead: the whole batch is on disk before totals change or we ack.
      :ok = IO.binwrite(state.file, Enum.map(accepted, &[JSON.encode!(&1), ?\n]))
      :ok = :file.datasync(state.file)
      Enum.each(accepted, &apply_event/1)
    end

    recent = Enum.take(Enum.reverse(accepted) ++ state.recent, @recent)
    {:reply, {:ok, Map.put(counts, :accepted, length(accepted))}, %{state | recent: recent}}
  end

  def handle_call(:recent, _from, state), do: {:reply, state.recent, state}

  def handle_call({:prune_ids, cutoff_ms}, _from, state) do
    dropped = :ets.select_delete(@seen, [{{:_, :"$1"}, [{:<, :"$1", cutoff_ms}], [true]}])
    {:reply, dropped, state}
  end

  # Splits a batch into events to record, in order, plus duplicate/invalid counts.
  defp classify(events, kind) do
    {accepted, _ids, counts} =
      Enum.reduce(events, {[], MapSet.new(), %{duplicates: 0, invalid: 0}}, fn event, {acc, ids, counts} ->
        id = is_map(event) && event["id"]

        cond do
          not valid?(event) ->
            {acc, ids, %{counts | invalid: counts.invalid + 1}}

          id && (MapSet.member?(ids, id) or :ets.member(@seen, id)) ->
            {acc, ids, %{counts | duplicates: counts.duplicates + 1}}

          true ->
            ids = if id, do: MapSet.put(ids, id), else: ids
            {[enrich(event, kind) | acc], ids, counts}
        end
      end)

    {Enum.reverse(accepted), counts}
  end

  # Media job events are priced by the job runner; only timestamps are added.
  defp enrich(event, :media) do
    cost = if is_number(event["cost_usd"]) and event["cost_usd"] >= 0, do: event["cost_usd"] * 1.0, else: 0.0

    event
    |> Map.merge(%{"kind" => "media", "cost_usd" => cost})
    |> stamp()
  end

  defp enrich(usage, :text) do
    # Only the control plane may mark an event as media.
    usage = Map.delete(usage, "kind")
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    cost =
      case usage["upstream"] do
        nil -> 0.0
        up -> cost(input, output, OmnigateControl.ConfigStore.price(usage["route_model"], up, usage["target_model"]))
      end

    usage |> Map.put("cost_usd", cost) |> stamp()
  end

  # `ts` is when the request finished on the data plane, not when the event
  # reached us: events can arrive late after an outage.
  defp stamp(event) do
    ts =
      case event["ts_ms"] do
        ms when is_integer(ms) -> DateTime.from_unix!(ms, :millisecond)
        _ -> DateTime.utc_now()
      end

    Map.merge(event, %{
      "ts" => DateTime.to_iso8601(ts),
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp apply_event(event) do
    # Kept with the time we recorded it, so old ids can be pruned.
    if id = event["id"], do: :ets.insert(@seen, {id, recorded_ms(event)})

    add(event["key_sha256"], event)

    # One extra row per UTC day (of the event's own time), for "today" figures.
    case event["ts"] do
      <<day::binary-size(10), _rest::binary>> -> add({:day, day}, event)
      _ -> :ok
    end
  end

  defp add(row, event) do
    t =
      case :ets.lookup(@table, row) do
        [{_, totals}] -> totals
        [] -> empty_totals()
      end

    :ets.insert(
      @table,
      {row,
       %{
         t
         | requests: t.requests + 1,
           errors: t.errors + if(event["status"] >= 400, do: 1, else: 0),
           input_tokens: t.input_tokens + (event["input_tokens"] || 0),
           output_tokens: t.output_tokens + (event["output_tokens"] || 0),
           jobs: t.jobs + if(event["kind"] == "media", do: 1, else: 0),
           cost_usd: t.cost_usd + (event["cost_usd"] || 0.0)
       }}
    )
  end

  defp recorded_ms(event) do
    with at when is_binary(at) <- event["received_at"],
         {:ok, dt, _offset} <- DateTime.from_iso8601(at) do
      DateTime.to_unix(dt, :millisecond)
    else
      _ -> System.os_time(:millisecond)
    end
  end

  defp replay(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(0, fn line, n ->
        # A torn final line (crash mid-write) is skipped, not fatal.
        case JSON.decode(line) do
          {:ok, event} ->
            apply_event(event)
            n + 1

          {:error, _} ->
            Logger.warning("ledger: skipping unreadable line during replay")
            n
        end
      end)
    else
      0
    end
  end

  defp empty_totals,
    do: %{requests: 0, errors: 0, input_tokens: 0, output_tokens: 0, jobs: 0, cost_usd: 0.0}
end
