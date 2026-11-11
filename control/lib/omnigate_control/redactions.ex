defmodule OmnigateControl.Redactions do
  @moduledoc """
  How many values privacy mode replaced before a provider saw them, by key
  and by class (`email`, `phone`, `card`, `ip`, `secret`).

  Counts only: a data plane reports them with its other counters
  (`POST /internal/counters`, reasons `redacted_<class>`), and never what
  was replaced. In memory, from zero at each start, like
  `OmnigateControl.Rejections`.
  """

  @table :omnigate_redactions
  @max_series 2_000

  @doc "Create the table. Call once at boot."
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc "Is this counter one of ours?"
  def counter?(%{"reason" => "redacted_" <> _}), do: true
  def counter?(_), do: false

  @doc "Add a batch of counters; malformed entries are ignored. Returns how many were accepted."
  def record(counters) when is_list(counters) do
    Enum.count(counters, fn
      %{"key" => key, "reason" => "redacted_" <> class, "count" => count} when is_binary(key) and is_integer(count) ->
        if class in OmnigateControl.Privacy.classes() and count > 0 and count <= 1_000_000_000 and byte_size(key) in 1..64 and String.printable?(key) do
          pair = {key, class}
          series = if :ets.member(@table, pair) or :ets.info(@table, :size) < @max_series, do: pair, else: {"-", class}
          :ets.update_counter(@table, series, count, {series, 0})
          true
        else
          false
        end

      _ ->
        false
    end)
  end

  def record(_), do: 0

  @doc "Every series as `%{key, class, count}`, largest count first."
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{key, class}, count} -> %{key: key, class: class, count: count} end)
    |> Enum.sort_by(&{-&1.count, &1.key, &1.class})
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)
end
