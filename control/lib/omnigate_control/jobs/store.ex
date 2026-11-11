defmodule OmnigateControl.Jobs.Store do
  @moduledoc """
  Durable job state.

  A new job appends its full snapshot to a JSONL log; every later change
  appends only the fields that changed (a patch line), so a job's input is
  written once, not on every state change. Each line is synced to disk before
  the change is visible, then an ETS table that reads go to directly is
  updated. On boot the log is replayed (snapshots, then patches applied in
  order) and rewritten compacted, so it does not grow across restarts. While
  running, the log is compacted again whenever it holds well over twice as
  many lines as there are jobs, so a process that never restarts does not
  leave a long history for the next boot either. Boot therefore reads a file
  proportional to the jobs that are kept, not to every state change made.

  `purge_finished_before/1` removes old finished jobs for good and compacts
  the log again, which is how `OmnigateControl.Retention` keeps it bounded.

  Jobs are JSON-shaped maps with string keys. All writes go through this
  process, so `update/2` functions run one at a time.

  ## What this process survives

  It holds every job, so nothing a caller hands it may take it down:

    * text that is not valid UTF-8 (a provider's error body, a header value)
      cannot be written as JSON; it is repaired before it is stored
      (`OmnigateControl.Text`), and if a line still cannot be encoded or
      written the caller gets `{:error, reason}` and the job is unchanged;
    * an `update/2` function that raises gives its caller `{:error, :update_failed}`.

  ## Tables

  Reads do not go through the process. Three tables, all filled under a
  private name during boot and given their public name only when the log has
  been replayed, so a reader never sees half of the jobs (a missing table
  raises; a missing job would be an answer):

    * the jobs by id;
    * an index: idempotency keys, cache keys, and per-key counters of
      unfinished jobs and of jobs created per UTC day;
    * an ordered index by creation time, per key and overall, so listing a
      key's newest jobs reads those jobs and nothing else.

  ## Large inputs

  A job's input can be up to `media.max_input_bytes` (1 MiB by default). The
  job record is copied out of the table on every read, so an input above a
  few KiB is kept in a file of its own next to the log (`<log>.inputs/<id>.json`)
  and the record only says so (see `OmnigateControl.Jobs.input/1`).
  """
  use GenServer
  require Logger

  alias OmnigateControl.Text

  @table :omnigate_jobs
  @index :omnigate_jobs_index
  @order :omnigate_jobs_order

  @terminal ~w(succeeded failed canceled)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Insert a new job. With an idempotency key that was already used by the same
  gateway key, returns `{:existing, job}` and inserts nothing.

  `caps` may hold `open_cap: {limit, hashes}` (refuse with
  `{:error, :too_many_open}` when the gateway key already has `limit`
  unfinished jobs) and `day_cap: {limit, hashes}` (`{:error, :too_many_today}`
  when it already created `limit` jobs this UTC day). `hashes` are the key's
  current and earlier secrets' hashes, so a rotation does not reset a count.
  Both are checked inside the store, so two requests cannot both take the
  last slot. A limit of 0 means none.
  """
  def create(job, caps \\ [])
  def create(job, {limit, hashes}) when is_integer(limit) and is_list(hashes), do: create(job, open_cap: {limit, hashes})
  def create(job, caps) when is_list(caps), do: GenServer.call(__MODULE__, {:create, job, caps})

  @doc "Unfinished jobs created under any of `hashes` (canceled ones whose provider call is still in flight included)."
  def open_count(hashes) when is_list(hashes), do: sum_counters(@index, for(hash <- hashes, do: {:open, hash}))

  @doc "Jobs created under any of `hashes` on the UTC day of `now_ms`."
  def day_count(hashes, now_ms \\ System.os_time(:millisecond)) when is_list(hashes) do
    sum_counters(@index, for(hash <- hashes, do: {:day, hash, day_of(now_ms)}))
  end

  defp sum_counters(index, rows) do
    Enum.reduce(rows, 0, fn row, sum ->
      case :ets.lookup(index, row) do
        [{_, n}] -> sum + n
        [] -> sum
      end
    end)
  end

  @doc """
  Apply `fun` to the current job. `fun` returns the new job, or `:noop` to
  leave it alone. Returns `{:ok, job}`, `:noop`, `:not_found`, or
  `{:error, reason}` when the change could not be made (the job is then
  unchanged).
  """
  def update(id, fun) when is_function(fun, 1), do: GenServer.call(__MODULE__, {:update, id, fun})

  def get(id) do
    case :ets.lookup(@table, id) do
      [{_, job}] -> job
      [] -> nil
    end
  end

  @doc "All jobs, unordered. Copies every record: for sweeps and tests, not for request paths."
  def all, do: :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))

  @doc "Fold `fun.(job, acc)` over every job without building the whole list."
  def fold(acc, fun) when is_function(fun, 2), do: :ets.foldl(fn {_id, job}, acc -> fun.(job, acc) end, acc, @table)

  @doc "How many jobs are held."
  def count, do: :ets.info(@table, :size)

  @doc "Jobs created with one gateway key, newest first. Reads `limit` jobs, however many the key has."
  def list_for_key(key_sha256, limit), do: newest({:key, key_sha256, :newest, nil}, &match?({:key, ^key_sha256, _, _}, &1), limit)

  @doc "Newest jobs across all keys."
  def recent(limit), do: newest({:all, :newest, nil}, &match?({:all, _, _}, &1), limit)

  # Walk the ordered index backwards from just above the newest entry of one
  # group. (An atom sorts above every number, so `:newest` is past any time.)
  defp newest(start, in_group?, limit) do
    start
    |> Stream.unfold(fn at ->
      case :ets.prev(@order, at) do
        :"$end_of_table" -> nil
        key -> if in_group?.(key), do: {key, key}, else: nil
      end
    end)
    |> Stream.map(fn key -> get(elem(key, tuple_size(key) - 1)) end)
    |> Stream.reject(&is_nil/1)
    |> Enum.take(max(limit, 0))
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

  @doc "Has gateway key `key_sha256` already created a job with this idempotency key?"
  def idempotent?(key_sha256, idempotency_key), do: :ets.member(@index, {:idem, key_sha256, idempotency_key})

  @doc "Ids of finished jobs whose cost is not in the ledger yet, and of jobs whose webhook is waiting to be sent."
  def unsettled do
    unledgered = :ets.select(@table, for(status <- @terminal, do: {{:"$1", %{"status" => status, "ledgered" => false}}, [], [:"$1"]}))

    webhooks =
      :ets.select(
        @table,
        for(state <- ["pending", "retrying"], do: {{:"$1", %{"webhook" => %{"status" => state, "next_attempt_ms" => :"$2"}}}, [], [{{:"$1", :"$2"}}]})
      )

    %{unledgered: unledgered, webhooks: webhooks}
  end

  # -- large inputs ----------------------------------------------------------

  @doc "Where the input of job `id` is kept when it is too large for the record."
  def input_path(id) when is_binary(id) do
    if id =~ ~r/\Ajob_[A-Za-z0-9]{1,64}\z/ do
      Path.join(:persistent_term.get({__MODULE__, :inputs_dir}), id <> ".json")
    else
      raise ArgumentError, "not a job id: #{inspect(id)}"
    end
  end

  @doc "Write the JSON of a job's input to its file, synced. `:ok` or `{:error, reason}`."
  def put_input(id, json) when is_binary(json) do
    path = input_path(id)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, json, [:sync])
  end

  @doc "The input kept on disk for job `id`: `{:ok, map}` or `:error`."
  def read_input(id) do
    with {:ok, json} <- File.read(input_path(id)),
         {:ok, %{} = input} <- JSON.decode(json) do
      {:ok, input}
    else
      _ -> :error
    end
  end

  def delete_input(id), do: File.rm(input_path(id))

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    :persistent_term.put({__MODULE__, :inputs_dir}, path <> ".inputs")

    # Filled under private names; see "Tables" above.
    loading = fn name -> :"#{name}_loading" end
    :ets.new(loading.(@table), [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(loading.(@index), [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(loading.(@order), [:named_table, :ordered_set, :protected, read_concurrency: true])
    tables = {:ets.whereis(loading.(@table)), :ets.whereis(loading.(@index)), :ets.whereis(loading.(@order))}
    Process.put(:tables, tables)

    {count, lines} = replay(path)
    if count > 0, do: Logger.info("job store replayed #{count} jobs from #{path}")
    # Rewriting a file that already has one line per job would only cost time.
    if lines != count, do: compact(path)
    sweep_inputs(path <> ".inputs")
    Process.put(:appended, 0)
    Process.send_after(self(), :maybe_compact, compact_check_ms())

    {jobs, index, order} = tables
    :ets.rename(jobs, @table)
    :ets.rename(index, @index)
    :ets.rename(order, @order)

    {:ok, %{path: path, file: File.open!(path, [:append, :binary])}}
  end

  defp tab, do: Process.get(:tables) |> elem(0)
  defp idx, do: Process.get(:tables) |> elem(1)
  defp ord, do: Process.get(:tables) |> elem(2)

  defp fetch(id) do
    case :ets.lookup(tab(), id) do
      [{_, job}] -> job
      [] -> nil
    end
  end

  defp every, do: :ets.tab2list(tab()) |> Enum.map(&elem(&1, 1))

  # An input file whose job is not in the log was written for a job that was
  # then refused, or belongs to a job purged just before a crash.
  defp sweep_inputs(dir) do
    with {:ok, names} <- File.ls(dir) do
      for name <- names, String.ends_with?(name, ".json"), fetch(String.replace_suffix(name, ".json", "")) == nil do
        File.rm(Path.join(dir, name))
      end
    end

    :ok
  end

  # Every job change appends a line. Once the lines written since the last
  # compaction outnumber the jobs twice over (and a floor, so small stores are
  # left alone), rewrite the log down to one line per job.
  @impl true
  def handle_info(:maybe_compact, state) do
    appended = Process.get(:appended, 0)
    floor = Application.get_env(:omnigate_control, :jobs_compact_min_lines, 5_000)

    state =
      if appended > max(floor, 2 * :ets.info(tab(), :size)) do
        recompact(state, "job store compacted its log (#{appended} lines since the last time)")
      else
        state
      end

    forget_old_days()
    Process.send_after(self(), :maybe_compact, compact_check_ms())
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp compact_check_ms, do: Application.get_env(:omnigate_control, :jobs_compact_check_ms, 60_000)

  # A failed rewrite (a full disk) leaves the old log, which is still right.
  defp recompact(state, message) do
    File.close(state.file)

    try do
      compact(state.path)
      Process.put(:appended, 0)
      if message, do: Logger.info(message)
    rescue
      e -> Logger.error("job store: rewriting the log failed, keeping the old one: #{Text.line(Exception.message(e))}")
    end

    %{state | file: File.open!(state.path, [:append, :binary])}
  end

  # Per-day creation counters are only read for the current day.
  defp forget_old_days do
    today = day_of(System.os_time(:millisecond))
    :ets.select_delete(idx(), [{{{:day, :_, :"$1"}, :_}, [{:<, :"$1", today}], [true]}])
  end

  @impl true
  def handle_call({:create, job, caps}, _from, state) do
    job = if Text.dirty?(job), do: Text.clean(job), else: job
    idem = idem_key(job)

    case idem && :ets.lookup(idx(), idem) do
      [{_, id}] ->
        {:reply, {:existing, fetch(id)}, state}

      _ ->
        cond do
          over?(caps[:open_cap], &sum_counters(idx(), for(hash <- &1, do: {:open, hash}))) ->
            {:reply, {:error, :too_many_open}, state}

          over?(caps[:day_cap], &sum_counters(idx(), for(hash <- &1, do: {:day, hash, day_of(job["created_ms"] || System.os_time(:millisecond))}))) ->
            {:reply, {:error, :too_many_today}, state}

          true ->
            # Write-ahead: on disk before anyone can observe the change.
            case append(state, job) do
              {:ok, state} ->
                index(job)
                count_day(job, 1)
                {:reply, {:ok, job}, state}

              {{:error, reason}, state} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call({:update, id, fun}, _from, state) do
    case fetch(id) do
      nil ->
        {:reply, :not_found, state}

      job ->
        result =
          try do
            fun.(job)
          catch
            kind, reason ->
              Logger.error("job store: an update of #{Text.line(id, 80)} failed: #{Text.line(Exception.format(kind, reason, __STACKTRACE__), 600)}")
              {:error, :update_failed}
          end

        case result do
          :noop ->
            {:reply, :noop, state}

          %{} = new ->
            new = Map.put(new, "updated_at", now_iso())

            case persist_change(state, job, new) do
              {{:ok, new}, state} -> {:reply, {:ok, new}, state}
              {{:error, reason}, state} -> {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          _other ->
            {:reply, {:error, :update_failed}, state}
        end
    end
  end

  def handle_call({:purge, cutoff_ms}, _from, state) do
    case Enum.filter(every(), &purgeable?(&1, cutoff_ms)) do
      [] ->
        {:reply, [], state}

      doomed ->
        Enum.each(doomed, &unindex/1)
        # The log must lose them too, or a restart would bring them back. The
        # rewrite is atomic (temp file, then rename); if we crash before it,
        # the old log is replayed and the next sweep removes them again.
        state = recompact(state, nil)
        for %{"input_file" => true, "id" => id} <- doomed, do: delete_input(id)
        {:reply, doomed, state}
    end
  end

  defp over?({limit, hashes}, count) when is_integer(limit) and limit > 0 and is_list(hashes), do: count.(hashes) >= limit
  defp over?(_, _count), do: false

  defp purgeable?(job, cutoff_ms) do
    job["status"] in @terminal and is_integer(job["finished_ms"]) and
      job["finished_ms"] < cutoff_ms and job["ledgered"] == true and
      not match?(%{"status" => s} when s in ["pending", "retrying"], job["webhook"])
  end

  defp unindex(job) do
    id = job["id"]
    if open?(job), do: count_open(job["key_sha256"], -1)
    :ets.delete(tab(), id)
    Enum.each(order_keys(job), &:ets.delete(ord(), &1))

    idem = idem_key(job)
    if idem && :ets.lookup(idx(), idem) == [{idem, id}], do: :ets.delete(idx(), idem)

    with key when is_binary(key) <- job["cache_key"],
         [{_, ^id, _}] <- :ets.lookup(idx(), {:cache, key}) do
      :ets.delete(idx(), {:cache, key})
    end

    :ok
  end

  # Only what changed goes to disk: a patch line naming the job, the fields
  # with new values and the fields that went away. A job's input is therefore
  # written once, when the job is created.
  defp persist_change(state, old, new) do
    changed = for {field, value} <- new, Map.get(old, field, :__absent__) != value, into: %{}, do: {field, value}

    # Whatever the change carries (a provider's words, mostly) is made
    # storable here, whoever forgot to do it earlier.
    {changed, new} =
      if Text.dirty?(changed) do
        clean = Text.clean(changed)
        {clean, Map.merge(new, clean)}
      else
        {changed, new}
      end

    dropped = Map.keys(old) -- Map.keys(new)

    case append(state, %{"id" => new["id"], "_patch" => changed, "_drop" => dropped}) do
      {:ok, state} ->
        index(new)
        {{:ok, new}, state}

      {{:error, reason}, state} ->
        {{:error, reason}, state}
    end
  end

  # `{:ok, state}` once the line is on disk, else `{{:error, reason}, state}`
  # with nothing changed. Never raises: a line that cannot be encoded or a
  # disk that cannot be written is the caller's error to handle, not a reason
  # to lose every other job's process.
  defp append(state, line) do
    with {:ok, json} <- encode(line),
         :ok <- IO.binwrite(state.file, [json, ?\n]),
         :ok <- :file.datasync(state.file) do
      Process.put(:appended, Process.get(:appended, 0) + 1)
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("job store: could not write a change for #{Text.line(line["id"], 80)}: #{Text.line(reason, 200)}")
        # A handle that failed once may be dead for good; a fresh one costs nothing.
        File.close(state.file)

        case File.open(state.path, [:append, :binary]) do
          {:ok, file} -> {{:error, :write_failed}, %{state | file: file}}
          _ -> {{:error, :write_failed}, state}
        end
    end
  end

  defp encode(line) do
    {:ok, JSON.encode!(line)}
  rescue
    e -> {:error, "not encodable as JSON: " <> Exception.message(e)}
  end

  # Unfinished, or canceled while its provider call is still in flight (see
  # `Jobs.cancel/2`): that call is still running at the provider, so the job
  # keeps its place in the key's open-jobs limit until it is accounted for.
  defp open?(nil), do: false
  defp open?(job), do: job["status"] not in @terminal or job["provider_pending"] == true

  defp count_open(key, delta) when is_binary(key) and delta != 0 do
    :ets.update_counter(idx(), {:open, key}, delta, {{:open, key}, 0})
  end

  defp count_open(_key, _delta), do: :ok

  defp count_day(%{"key_sha256" => key, "created_ms" => ms}, delta) when is_binary(key) and is_integer(ms) do
    :ets.update_counter(idx(), {:day, key, day_of(ms)}, delta, {{:day, key, day_of(ms)}, 0})
  end

  defp count_day(_job, _delta), do: :ok

  defp day_of(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

  defp order_keys(%{"id" => id, "created_ms" => ms} = job) when is_integer(ms) do
    [{:all, ms, id}] ++ if(is_binary(job["key_sha256"]), do: [{:key, job["key_sha256"], ms, id}], else: [])
  end

  defp order_keys(_job), do: []

  defp index(job) do
    # Keep the per-key count of unfinished jobs in step with every change.
    was_open = open?(fetch(job["id"]))
    is_open = open?(job)
    if is_open != was_open, do: count_open(job["key_sha256"], if(is_open, do: 1, else: -1))

    :ets.insert(tab(), {job["id"], job})
    :ets.insert(ord(), Enum.map(order_keys(job), &{&1}))
    if idem = idem_key(job), do: :ets.insert(idx(), {idem, job["id"]})

    if job["status"] == "succeeded" and job["cached"] != true and is_binary(job["cache_key"]) do
      :ets.insert(idx(), {{:cache, job["cache_key"]}, job["id"], job["finished_ms"] || 0})
    end
  end

  defp idem_key(%{"idempotency_key" => idem, "key_sha256" => key}) when is_binary(idem), do: {:idem, key, idem}
  defp idem_key(_), do: nil

  defp replay(path) do
    if File.exists?(path) do
      today = day_of(System.os_time(:millisecond))

      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(0, fn line, lines ->
        # A torn final line (crash mid-write) is skipped, not fatal. It still
        # counts as a line, so the file is rewritten without it.
        case JSON.decode(line) do
          {:ok, %{"id" => id, "_patch" => %{} = changed} = patch} ->
            case fetch(id) do
              nil -> Logger.warning("job store: skipping a change to unknown job #{Text.line(id, 80)} during replay")
              job -> job |> Map.merge(changed) |> Map.drop(List.wrap(patch["_drop"])) |> index()
            end

          {:ok, %{"id" => id} = job} when is_binary(id) ->
            first = fetch(id) == nil
            index(job)
            # Today's creations count towards today's limit after a restart too.
            if first and is_integer(job["created_ms"]) and day_of(job["created_ms"]) == today, do: count_day(job, 1)

          _ ->
            Logger.warning("job store: skipping unreadable line during replay")
        end

        lines + 1
      end)
      |> then(&{:ets.info(tab(), :size), &1})
    else
      {0, 0}
    end
  end

  # Rewrite the log with one line per job. Atomic: write a sibling file, then rename.
  defp compact(path) do
    tmp = path <> ".compact"
    lines = every() |> Enum.sort_by(& &1["created_ms"]) |> Enum.map(&[JSON.encode!(&1), ?\n])
    File.write!(tmp, lines, [:sync])
    File.rename!(tmp, path)
  end

  def now_iso, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
