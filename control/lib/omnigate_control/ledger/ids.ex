defmodule OmnigateControl.Ledger.Ids do
  @moduledoc """
  The ids of recorded usage events, kept so that an event sent twice is
  counted once.

  ## Shape

  An id is kept as 118 bits of its SHA-256, as two small integers: 16 bytes
  on disk, and one `{a, b}` row in an ETS table in memory, about 61 MiB per
  million ids, half of what a `{"<32 hex chars>", milliseconds}` row costs.
  (The hash, not the id's own bytes, although a data plane's ids are 16
  random bytes already: ids are whatever the sender made them, job ids
  included, and cutting bits off ids that happen to differ only in those bits
  would call different events duplicates. Two different ids share 118 hash
  bits about once in 10^35 pairs.)

  There is one table, and one file, per UTC day on which ids were recorded:

      ledger.ids.2026-11-10        16 bytes per id, appended, never rewritten

  so forgetting old ids is deleting whole days (`drop_before/2`): no scan of
  a big table, no rewrite of a big file. The price is that the window is in
  whole days: an id is kept for at least `retention.ledger_ids_days` and at
  most one day longer.

  ## Why they are not in the snapshot

  They used to be, which made every snapshot as large as the id set and
  stalled the ledger while it was written (seconds per million ids). Now a
  batch appends its ids to the day's file, and a snapshot only records how
  long each file was when it was taken (`sizes/1`), after syncing it.

  At boot each file is cut back to the length the snapshot knew
  (`load/3`): the ids after that belong to events after the snapshot, which
  are replayed and add their ids again. With no snapshot, or one from before
  this layout, the files are discarded and rebuilt from the events
  (`reset/2`). Either way the set in memory after boot is exactly the ids of
  the events that were counted, which is what lets the replay skip an event
  whose id is already there instead of counting it twice.

  The struct is owned and used by the ledger process only.
  """
  require Logger

  defstruct path: nil, registry: nil, days: %{}, open: nil

  @record 16
  @read_chunk 65_536 * @record

  @doc "The file holding the ids recorded on `day` (`\"YYYY-MM-DD\"`) for the ledger at `path`."
  def file(path, day), do: Path.rootname(path) <> ".ids." <> day

  @doc "Id files next to the ledger at `path`, as `[{day, file}]`, oldest first."
  def files(path) do
    dir = Path.dirname(path)
    prefix = Path.basename(Path.rootname(path)) <> ".ids."

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, prefix), day = String.replace_prefix(name, prefix, ""), day =~ ~r/\A\d{4}-\d{2}-\d{2}\z/ do
          {day, Path.join(dir, name)}
        end
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "The two integers an id is remembered as."
  def key(id) when is_binary(id) do
    <<a::59, b::59, _::bitstring>> = :crypto.hash(:sha256, id)
    {a, b}
  end

  @doc "An empty set for the ledger at `path`; any id files left there are deleted."
  def reset(path, registry) do
    for {_day, file} <- files(path), do: File.rm(file)
    %__MODULE__{path: path, registry: registry}
  end

  @doc """
  Load the id files of the ledger at `path`, each cut back to the length in
  `covered` (`%{day => bytes}`, from a snapshot). A file the snapshot does
  not know is removed: it was started after the snapshot was taken.
  """
  def load(path, registry, covered) when is_map(covered) do
    found = files(path)
    present = MapSet.new(found, &elem(&1, 0))

    # A day the snapshot counted ids for, without its file: those ids are
    # gone, and an event of that day that is sent again would be counted a
    # second time. Nothing here can bring them back; say so.
    for {day, bytes} <- Enum.sort(covered), is_integer(bytes) and bytes > 0, not MapSet.member?(present, day) do
      Logger.warning(
        "ledger: the id file for #{day} (#{file(path, day)}) is missing; the snapshot recorded #{div(bytes, @record)} ids in it. " <>
          "A usage event of that day that is delivered again will be counted twice"
      )
    end

    Enum.reduce(found, %__MODULE__{path: path, registry: registry}, fn {day, file}, ids ->
      case covered do
        %{^day => bytes} when is_integer(bytes) and bytes > 0 ->
          keep = min(bytes, File.stat!(file).size) |> then(&(&1 - rem(&1, @record)))
          truncate(file, keep)
          tid = table(ids, day)
          read_into(file, tid)
          %{ids | days: Map.put(ids.days, day, %{tid: tid, bytes: keep})}

        _ ->
          File.rm(file)
          ids
      end
    end)
  end

  defp truncate(file, keep) do
    if File.stat!(file).size > keep do
      {:ok, io} = :file.open(file, [:read, :write, :binary, :raw])
      {:ok, _} = :file.position(io, keep)
      :ok = :file.truncate(io)
      :ok = :file.datasync(io)
      :ok = :file.close(io)
    end
  end

  defp read_into(file, tid) do
    {:ok, io} = :file.open(file, [:read, :binary, :raw])
    read_chunks(io, tid)
    :file.close(io)
  end

  defp read_chunks(io, tid) do
    case :file.read(io, @read_chunk) do
      {:ok, bytes} ->
        :ets.insert(tid, for(<<a::59, b::59, _::10 <- bytes>>, do: {a, b}))
        read_chunks(io, tid)

      _ ->
        :ok
    end
  end

  @doc "Was an event with this key (see `key/1`) recorded on any day still held?"
  def member?(%__MODULE__{days: days}, {a, b} = key) do
    Enum.any?(days, fn {_day, %{tid: tid}} ->
      case :ets.lookup(tid, a) do
        [] -> false
        [{^a, ^b}] -> true
        rows -> key in rows
      end
    end)
  end

  @doc "Remember `keys` as recorded on `day`: in memory, and appended to the day's file (not synced; see `sync/1`)."
  def add(%__MODULE__{} = ids, [], _day), do: ids

  def add(%__MODULE__{} = ids, keys, day) do
    ids = if Map.has_key?(ids.days, day), do: ids, else: %{ids | days: Map.put(ids.days, day, %{tid: table(ids, day), bytes: 0})}
    %{tid: tid, bytes: bytes} = ids.days[day]
    :ets.insert(tid, keys)
    data = for {a, b} <- keys, into: <<>>, do: <<a::59, b::59, 0::10>>
    ids = open(ids, day)

    case ids.open do
      {^day, io} ->
        case :file.write(io, data) do
          :ok ->
            %{ids | days: Map.put(ids.days, day, %{tid: tid, bytes: bytes + byte_size(data)})}

          error ->
            # Still remembered in memory; only a restart would forget them.
            Logger.error("ledger: could not append to #{Path.basename(file(ids.path, day))}: #{inspect(error)}")
            ids
        end

      _ ->
        ids
    end
  end

  defp open(%__MODULE__{open: {day, _io}} = ids, day), do: ids

  defp open(%__MODULE__{} = ids, day) do
    ids = close(ids)
    target = file(ids.path, day)
    # A torn tail (a crash mid-append) must not shift the records after it.
    if File.exists?(target), do: truncate(target, ids.days[day].bytes)

    case :file.open(target, [:append, :binary, :raw]) do
      {:ok, io} ->
        %{ids | open: {day, io}}

      error ->
        Logger.error("ledger: could not open #{Path.basename(target)}: #{inspect(error)}")
        ids
    end
  end

  @doc "Flush the file being appended to. Called before a snapshot records the lengths."
  def sync(%__MODULE__{open: {_day, io}} = ids) do
    _ = :file.datasync(io)
    ids
  end

  def sync(ids), do: ids

  @doc "`%{day => bytes}`: how long each day's file is, for a snapshot."
  def sizes(%__MODULE__{days: days}), do: Map.new(days, fn {day, %{bytes: bytes}} -> {day, bytes} end)

  @doc "Forget every day before `day`. Returns `{ids, how_many_ids_went}`."
  def drop_before(%__MODULE__{} = ids, day) do
    Enum.reduce(ids.days, {ids, 0}, fn
      {d, %{tid: tid}}, {ids, dropped} when d < day ->
        n = :ets.info(tid, :size)
        ids = if match?({^d, _}, ids.open), do: close(ids), else: ids
        :ets.delete(tid)
        :ets.delete(ids.registry, d)
        File.rm(file(ids.path, d))
        {%{ids | days: Map.delete(ids.days, d)}, dropped + n}

      _, acc ->
        acc
    end)
  end

  @doc "Every key held, sorted (for tests)."
  def all(%__MODULE__{days: days}), do: days |> Enum.flat_map(fn {_day, %{tid: tid}} -> :ets.tab2list(tid) end) |> Enum.sort()

  @doc "How many ids are held, read from the registry table (any process may ask)."
  def count(registry) do
    registry |> :ets.tab2list() |> Enum.map(fn {_day, tid} -> :ets.info(tid, :size) end) |> Enum.filter(&is_integer/1) |> Enum.sum()
  rescue
    ArgumentError -> 0
  end

  def close(%__MODULE__{open: {_day, io}} = ids) do
    _ = :file.close(io)
    %{ids | open: nil}
  end

  def close(ids), do: ids

  defp table(%__MODULE__{registry: registry}, day) do
    tid = :ets.new(:omnigate_ledger_ids_day, [:bag, :protected])
    :ets.insert(registry, {day, tid})
    tid
  end
end
