defmodule OmnigateControl.Ledger do
  @moduledoc """
  Durable usage ledger.

  Every usage record is appended to a JSONL event log before it is
  acknowledged, then folded into an ETS table of per-key totals. On boot the
  log is replayed, so spend survives restarts.

  Next step for multi-node: replicate events across the cluster (e.g. via
  `:pg` or a Raft log) so budgets are enforced cluster-wide.
  """
  use GenServer
  require Logger

  @table :omnigate_ledger_totals
  @recent 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record one usage event from a data plane. Returns the computed cost."
  def record(usage) when is_map(usage), do: GenServer.call(__MODULE__, {:record, usage})

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

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    replayed = replay(path)
    if replayed > 0, do: Logger.info("ledger replayed #{replayed} events from #{path}")

    file = File.open!(path, [:append, :binary])
    {:ok, %{file: file, recent: []}}
  end

  @impl true
  def handle_call({:record, usage}, _from, state) do
    event = enrich(usage)
    # Write-ahead: the event is on disk before we update totals or ack.
    :ok = IO.binwrite(state.file, [JSON.encode!(event), ?\n])
    :ok = :file.datasync(state.file)
    apply_event(event)
    recent = Enum.take([event | state.recent], @recent)
    {:reply, {:ok, event["cost_usd"]}, %{state | recent: recent}}
  end

  def handle_call(:recent, _from, state), do: {:reply, state.recent, state}

  defp enrich(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    cost =
      case usage["upstream"] do
        nil -> 0.0
        up -> cost(input, output, OmnigateControl.ConfigStore.price(usage["route_model"], up, usage["target_model"]))
      end

    Map.merge(usage, %{
      "cost_usd" => cost,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp apply_event(event) do
    key = event["key_sha256"]
    t = totals(key)

    :ets.insert(
      @table,
      {key,
       %{
         t
         | requests: t.requests + 1,
           errors: t.errors + if(event["status"] >= 400, do: 1, else: 0),
           input_tokens: t.input_tokens + (event["input_tokens"] || 0),
           output_tokens: t.output_tokens + (event["output_tokens"] || 0),
           cost_usd: t.cost_usd + (event["cost_usd"] || 0.0)
       }}
    )
  end

  defp replay(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(0, fn line, n ->
        apply_event(JSON.decode!(line))
        n + 1
      end)
    else
      0
    end
  end

  defp empty_totals,
    do: %{requests: 0, errors: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0.0}
end
