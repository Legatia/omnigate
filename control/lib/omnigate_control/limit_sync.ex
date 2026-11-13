defmodule OmnigateControl.LimitSync do
  @moduledoc """
  Passes on, between the data planes of this control plane, what each of them
  allowed its rate-limited keys, so that a key's `rpm` holds for all of them
  together and not for each on its own.

  A data plane decides every request from its own token buckets and never
  waits for anyone (`dataplane/src/ratelimit.zig`). About once a second it
  reports here what each limited key was allowed since its last report
  (`dataplane/src/limitsync.zig`); the answer is what the *other* data planes
  reported in the meantime, which it takes out of its buckets.

  This process only keeps, per data plane, what it has not been told yet. It
  holds no buckets and decides nothing. In memory only: after a restart the
  data planes are simply new to it again, and whatever was waiting to be
  passed on is forgiven, like the last minute of a restarted limiter.

  Bounds, since a report is input from the network (even if only holders of
  the internal token can send one): at most `@max_instances` data planes are
  known at once, one that has not reported for `@forget_after_ms` is
  forgotten with what was waiting for it, at most `@max_entries` entries of a
  report are read, and at most `@max_entries` keys wait for one data plane.
  """

  use GenServer

  @forget_after_ms 30_000
  @max_instances 64
  @max_entries 10_000
  @max_count 1_000_000_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  A report from the data plane `instance`: `taken` is a list of
  `%{"key" => sha256 hex, "n" => allowed, "rpm" => limit}`. Returns
  `{:ok, others, instances}` (what the other data planes allowed since this
  one last asked, in the same shape, and how many data planes are known) or
  `{:error, reason}` for a report that makes no sense.
  """
  def sync(instance, taken, now_ms \\ System.monotonic_time(:millisecond), server \\ __MODULE__) do
    cond do
      not valid_instance?(instance) -> {:error, "instance must be 1 to 64 characters of a-z, A-Z, 0-9, - or _"}
      not is_list(taken) -> {:error, "taken must be a list"}
      true -> GenServer.call(server, {:sync, instance, clean(taken), now_ms})
    end
  end

  @doc "How many data planes have reported recently."
  def instances(now_ms \\ System.monotonic_time(:millisecond), server \\ __MODULE__) do
    GenServer.call(server, {:instances, now_ms})
  catch
    :exit, _ -> 0
  end

  defp valid_instance?(id), do: is_binary(id) and byte_size(id) in 1..64 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  # Entries that make no sense are dropped, not refused: one odd entry must
  # not cost the rest of a report.
  defp clean(taken) do
    taken
    |> Enum.take(@max_entries)
    |> Enum.flat_map(fn
      %{"key" => key, "n" => n, "rpm" => rpm}
      when is_binary(key) and byte_size(key) == 64 and is_integer(n) and n > 0 and is_integer(rpm) and rpm > 0 and rpm <= 4_294_967_295 ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, key), do: [{key, min(n, @max_count), rpm}], else: []

      _ ->
        []
    end)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  # State: %{instance => %{seen: ms, waiting: %{key => {n, rpm}}}}.
  @impl true
  def handle_call({:sync, instance, taken, now_ms}, _from, state) do
    state = forget_idle(state, now_ms)

    if not Map.has_key?(state, instance) and map_size(state) >= @max_instances do
      {:reply, {:error, "too many data planes"}, state}
    else
      mine = Map.get(state, instance, %{waiting: %{}})
      others = for {key, {n, rpm}} <- mine.waiting, do: %{key: key, n: n, rpm: rpm}

      state =
        state
        |> Map.put(instance, %{seen: now_ms, waiting: %{}})
        |> Map.new(fn
          {^instance, entry} -> {instance, entry}
          {other, entry} -> {other, %{entry | waiting: add(entry.waiting, taken)}}
        end)

      {:reply, {:ok, others, map_size(state)}, state}
    end
  end

  def handle_call({:instances, now_ms}, _from, state) do
    state = forget_idle(state, now_ms)
    {:reply, map_size(state), state}
  end

  defp forget_idle(state, now_ms), do: Map.reject(state, fn {_id, entry} -> now_ms - entry.seen > @forget_after_ms end)

  defp add(waiting, taken) do
    Enum.reduce(taken, waiting, fn {key, n, rpm}, acc ->
      case acc do
        # A changed limit starts a new bucket in the data plane, so what was
        # allowed under the old one no longer counts.
        %{^key => {have, ^rpm}} -> Map.put(acc, key, {min(have + n, @max_count), rpm})
        %{^key => _} -> Map.put(acc, key, {n, rpm})
        _ when map_size(acc) >= @max_entries -> acc
        _ -> Map.put(acc, key, {n, rpm})
      end
    end)
  end
end
