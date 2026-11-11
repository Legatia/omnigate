defmodule OmnigateControl.Rejections do
  @moduledoc """
  Requests that data planes refused before routing them: a bad key, a rate
  limit, a model the key may not use, and so on.

  Such requests never reach the ledger (nothing was served, nothing is
  billed), so without this they would be invisible to operators. Data planes
  report them as counters, `POST /internal/counters`:

      {"counters": [{"key": "my-app", "reason": "rate_limit_exceeded", "count": 12}, ...]}

  `key` is the gateway key's name, or `"-"` when the request had no usable
  key. `reason` is the `error.code` the client was given.

  Counts live in memory only and restart from zero with the control plane,
  like any Prometheus counter. The number of distinct (key, reason) pairs is
  capped; reports beyond the cap are folded into one `other` series so that a
  hostile client cannot grow the table by inventing names.
  """

  @table :omnigate_rejections
  @max_series 2_000
  @overflow {"-", "other"}

  @doc "Create the table. Call once at boot."
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc "Add a batch of counters; malformed entries are ignored. Returns how many were accepted."
  def record(counters) when is_list(counters) do
    Enum.count(counters, fn
      %{"key" => key, "reason" => reason, "count" => count} when is_binary(key) and is_binary(reason) and is_integer(count) ->
        if valid?(key, reason, count) do
          series = series(key, reason)
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

  @doc "Every series as `%{key, reason, count}`, largest count first."
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{key, reason}, count} -> %{key: key, reason: reason, count: count} end)
    |> Enum.sort_by(&{-&1.count, &1.key, &1.reason})
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  defp valid?(key, reason, count) do
    count > 0 and count <= 1_000_000_000 and byte_size(key) in 1..64 and String.printable?(key) and
      reason =~ ~r/\A[a-z0-9_]{1,64}\z/
  end

  # A pair seen before keeps its own series; a new one gets one only while there is room.
  defp series(key, reason) do
    pair = {key, reason}

    if :ets.member(@table, pair) or :ets.info(@table, :size) < @max_series, do: pair, else: @overflow
  end
end
