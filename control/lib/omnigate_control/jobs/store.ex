defmodule OmnigateControl.Jobs.Store do
  @moduledoc """
  Durable job state.

  Every change to a job appends its full snapshot to a JSONL log and syncs it
  to disk before the change is visible, then updates an ETS table that reads
  go to directly. On boot the log is replayed (last snapshot per job wins)
  and rewritten compacted, so it does not grow across restarts. While
  running, the log is compacted again whenever it holds well over twice as
  many lines as there are jobs, so a process that never restarts does not
  leave a long history for the next boot either. Boot therefore reads a file
  proportional to the jobs that are kept, not to every state change made.

  `purge_finished_before/1` removes old finished jobs for good and compacts
  the log again, which is how `OmnigateControl.Retention` keeps it bounded.

  Jobs are JSON-shaped maps with string keys. All writes go through this
  process, so `update/2` functions run one at a time.
  """
  use GenServer
  require Logger

  @table :omnigate_jobs
  @index :omnigate_jobs_index

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Insert a new job. With an idempotency key that was already used by the same
  gateway key, returns `{:existing, job}` and inserts nothing.
  """
  def create(job), do: GenServer.call(__MODULE__, {:create, job})

  @doc """
  Apply `fun` to the current job. `fun` returns the new job, or `:noop` to
  leave it alone. Returns `{:ok, job}`, `:noop` or `:not_found`.
  """
  def update(id, fun) when is_function(fun, 1), do: GenServer.call(__MODULE__, {:update, id, fun})

  def get(id) do
    case :ets.lookup(@table, id) do
      [{_, job}] -> job
      [] -> nil
    end
  end

  @doc "All jobs, unordered."
  def all, do: :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))

  @doc "Jobs created with one gateway key, newest first."
  def list_for_key(key_sha256, limit) do
    all()
    |> Enum.filter(&(&1["key_sha256"] == key_sha256))
    |> Enum.sort_by(& &1["created_ms"], :desc)
    |> Enum.take(limit)
  end

  @doc "Newest jobs across all keys."
  def recent(limit) do
    all() |> Enum.sort_by(& &1["created_ms"], :desc) |> Enum.take(limit)
  end

  @doc """
  Forget every finished job that finished before `cutoff_ms` (unix
  milliseconds) and rewrite the log without them. Returns the removed jobs so
  the caller can delete their files.

  Only jobs with nothing left to do are removed: terminal, already in the
  ledger, and with no webhook delivery still pending. Their idempotency keys
  and cache entries go with them, so neither can point at a job that is gone.
  """
  def purge_finished_before(cutoff_ms) when is_integer(cutoff_ms) do
    GenServer.call(__MODULE__, {:purge, cutoff_ms}, 120_000)
  end

  @doc "Id of the latest succeeded, non-cached job stored under `cache_key`, with its finish time."
  def cache_lookup(cache_key) do
    case :ets.lookup(@index, {:cache, cache_key}) do
      [{_, id, finished_ms}] -> {id, finished_ms}
      [] -> nil
    end
  end

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@index, [:named_table, :set, :protected, read_concurrency: true])

    {count, lines} = replay(path)
    if count > 0, do: Logger.info("job store replayed #{count} jobs from #{path}")
    # Rewriting a file that already has one line per job would only cost time.
    if lines != count, do: compact(path)
    Process.put(:appended, 0)
    Process.send_after(self(), :maybe_compact, compact_check_ms())

    {:ok, %{path: path, file: File.open!(path, [:append, :binary])}}
  end

  # Every job change appends a line. Once the lines written since the last
  # compaction outnumber the jobs twice over (and a floor, so small stores are
  # left alone), rewrite the log down to one line per job.
  @impl true
  def handle_info(:maybe_compact, state) do
    appended = Process.get(:appended, 0)
    floor = Application.get_env(:omnigate_control, :jobs_compact_min_lines, 5_000)

    state =
      if appended > max(floor, 2 * :ets.info(@table, :size)) do
        File.close(state.file)
        compact(state.path)
        Process.put(:appended, 0)
        Logger.info("job store compacted its log (#{appended} lines since the last time)")
        %{state | file: File.open!(state.path, [:append, :binary])}
      else
        state
      end

    Process.send_after(self(), :maybe_compact, compact_check_ms())
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp compact_check_ms, do: Application.get_env(:omnigate_control, :jobs_compact_check_ms, 60_000)

  @impl true
  def handle_call({:create, job}, _from, state) do
    idem = idem_key(job)

    case idem && :ets.lookup(@index, idem) do
      [{_, id}] ->
        {:reply, {:existing, get(id)}, state}

      _ ->
        persist(state, job)
        {:reply, {:ok, job}, state}
    end
  end

  def handle_call({:update, id, fun}, _from, state) do
    case get(id) do
      nil ->
        {:reply, :not_found, state}

      job ->
        case fun.(job) do
          :noop ->
            {:reply, :noop, state}

          %{} = new ->
            new = Map.put(new, "updated_at", now_iso())
            persist(state, new)
            {:reply, {:ok, new}, state}
        end
    end
  end

  def handle_call({:purge, cutoff_ms}, _from, state) do
    case Enum.filter(all(), &purgeable?(&1, cutoff_ms)) do
      [] ->
        {:reply, [], state}

      doomed ->
        Enum.each(doomed, &unindex/1)
        # The log must lose them too, or a restart would bring them back. The
        # rewrite is atomic (temp file, then rename); if we crash before it,
        # the old log is replayed and the next sweep removes them again.
        File.close(state.file)
        compact(state.path)
        {:reply, doomed, %{state | file: File.open!(state.path, [:append, :binary])}}
    end
  end

  defp purgeable?(job, cutoff_ms) do
    job["status"] in ~w(succeeded failed canceled) and is_integer(job["finished_ms"]) and
      job["finished_ms"] < cutoff_ms and job["ledgered"] == true and
      not match?(%{"status" => s} when s in ["pending", "retrying"], job["webhook"])
  end

  defp unindex(job) do
    id = job["id"]
    :ets.delete(@table, id)

    idem = idem_key(job)
    if idem && :ets.lookup(@index, idem) == [{idem, id}], do: :ets.delete(@index, idem)

    with key when is_binary(key) <- job["cache_key"],
         [{_, ^id, _}] <- :ets.lookup(@index, {:cache, key}) do
      :ets.delete(@index, {:cache, key})
    end

    :ok
  end

  defp persist(state, job) do
    # Write-ahead: on disk before anyone can observe the change.
    :ok = IO.binwrite(state.file, [JSON.encode!(job), ?\n])
    :ok = :file.datasync(state.file)
    Process.put(:appended, Process.get(:appended, 0) + 1)
    index(job)
  end

  defp index(job) do
    :ets.insert(@table, {job["id"], job})
    if idem = idem_key(job), do: :ets.insert(@index, {idem, job["id"]})

    if job["status"] == "succeeded" and job["cached"] != true and is_binary(job["cache_key"]) do
      :ets.insert(@index, {{:cache, job["cache_key"]}, job["id"], job["finished_ms"] || 0})
    end
  end

  defp idem_key(%{"idempotency_key" => idem, "key_sha256" => key}) when is_binary(idem), do: {:idem, key, idem}
  defp idem_key(_), do: nil

  defp replay(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(0, fn line, lines ->
        # A torn final line (crash mid-write) is skipped, not fatal. It still
        # counts as a line, so the file is rewritten without it.
        case JSON.decode(line) do
          {:ok, %{"id" => _} = job} -> index(job)
          _ -> Logger.warning("job store: skipping unreadable line during replay")
        end

        lines + 1
      end)
      |> then(&{:ets.info(@table, :size), &1})
    else
      {0, 0}
    end
  end

  # Rewrite the log with one line per job. Atomic: write a sibling file, then rename.
  defp compact(path) do
    tmp = path <> ".compact"
    lines = all() |> Enum.sort_by(& &1["created_ms"]) |> Enum.map(&[JSON.encode!(&1), ?\n])
    File.write!(tmp, lines, [:sync])
    File.rename!(tmp, path)
  end

  def now_iso, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
