defmodule OmnigateControl.Counters do
  @moduledoc """
  A handful of process-wide counters for `GET /metrics`: things that are
  dropped or refused on purpose and would otherwise leave no trace.

  In memory only; they restart from zero with the control plane, like any
  Prometheus counter. The names are fixed in the code, so the table cannot
  grow.
  """

  @table :omnigate_counters

  @doc "Create the table. Call once at boot."
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc "Add `n` to the counter `name` (an atom)."
  def bump(name, n \\ 1) when is_atom(name) and is_integer(n) do
    :ets.update_counter(@table, name, n, {name, 0})
    :ok
  rescue
    # Counting must never be why something fails (a test that runs a piece
    # of the system without the application has no table).
    ArgumentError -> :ok
  end

  @doc """
  True the first time it is called with `what`, false afterwards: for things
  worth one log line, not one per request. Remembers at most a thousand
  different things; past that it answers false.
  """
  def once(what) do
    :ets.info(@table, :size) < 1_000 and :ets.insert_new(@table, {{:once, what}, true})
  rescue
    ArgumentError -> false
  end

  @doc "The current value of `name`."
  def get(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{_, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end
end
