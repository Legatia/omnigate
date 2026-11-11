defmodule OmnigateControl.Ledger.Files do
  @moduledoc """
  The ledger on disk. No process, no ETS: only files, so every step can be
  tested on its own, including what a crash between two steps leaves behind.

  ## Layout

  For a ledger path `dir/ledger.jsonl`:

    * `ledger.jsonl` — the **active segment**: one JSON event per line,
      appended and synced before a batch is acknowledged.
    * `ledger.000001.jsonl`, `ledger.000002.jsonl`, ... — **sealed segments**,
      older events in order. The active segment's number is one more than the
      highest sealed number, so an installation that only ever had
      `ledger.jsonl` is simply "segment 1, still active": nothing to migrate.
    * `ledger.snapshot` — everything a replay of the covered events would
      have produced, with the position it covers: `{segment, byte offset}`.
    * `ledger.snapshot.prev` — the snapshot before that, kept as a spare.
    * `ledger.snapshot.tmp` — a snapshot being written; never read.
    * `ledger.ids.YYYY-MM-DD` — the ids of the events recorded on that UTC
      day, 16 bytes each, for duplicate detection
      (`OmnigateControl.Ledger.Ids`).

  A ledger path without an extension works the same way (`ledger`,
  `ledger.000001`, `ledger.snapshot`, ...).

  ## Snapshot file

  `magic line, 32-byte SHA-256 of the payload, payload`, where the payload is
  `:erlang.term_to_binary/2` of a map. A snapshot is used only if the magic
  and checksum match, the term decodes, and the ledger bytes it claims to
  cover are still there and unchanged (a fingerprint of the first and last
  bytes before its offset). Anything else is ignored: the caller falls back
  to the spare, then to replaying every segment.

  ## Why each step is safe to crash in

    * **Appending**: a torn last line is cut off at boot (`repair_active/1`)
      before anything is appended after it. The batch it belonged to was
      never acknowledged, so the data plane sends it again.
    * **Snapshot**: written to `.tmp` and synced, then `snapshot` is renamed
      to `.prev`, then `.tmp` to `snapshot`. Before the first rename the old
      snapshot is intact; between the renames the old one is the spare and is
      used; after the second the new one is used. A snapshot is never the
      only record of an event that is still in a segment, so losing one costs
      time, not data.
    * **Sealing**: the active file is renamed to its numbered name, then a
      new empty active file is created. Between the two there is no active
      file, which boot treats as an empty one. A snapshot that pointed into
      the old active file still finds those bytes, under the numbered name.
    * **Deleting old segments**: only segments covered by *both* snapshots
      are deleted, so either snapshot alone still reproduces the totals. Any
      subset of the deletions may have happened. The newest sealed segment is
      never deleted, because the segment numbering is read from the file names.
  """
  require Logger

  @magic "OMNIGATE-LEDGER-SNAPSHOT-1\n"
  @fingerprint_bytes 4096

  # -- names -----------------------------------------------------------------

  def snapshot_path(path), do: stem(path) <> ".snapshot"
  def prev_path(path), do: snapshot_path(path) <> ".prev"
  def tmp_path(path), do: snapshot_path(path) <> ".tmp"

  def sealed_path(path, seq), do: stem(path) <> "." <> String.pad_leading(Integer.to_string(seq), 6, "0") <> Path.extname(path)

  defp stem(path), do: Path.rootname(path)

  @doc "Sealed segments as `[{seq, file}]`, oldest first."
  def sealed(path) do
    dir = Path.dirname(path)
    prefix = Path.basename(stem(path)) <> "."
    ext = Path.extname(path)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, prefix),
            String.ends_with?(name, ext),
            # `ext` is empty for a ledger path without an extension; the
            # sealed names are then `ledger.000001`, and nothing is stripped.
            middle = name |> String.replace_prefix(prefix, "") |> String.replace_suffix(ext, ""),
            middle =~ ~r/\A\d{6,}\z/ do
          {String.to_integer(middle), Path.join(dir, name)}
        end
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "The number the active segment has now (and will be sealed under)."
  def active_seq(path) do
    case List.last(sealed(path)) do
      {seq, _} -> seq + 1
      nil -> 1
    end
  end

  # -- the active segment ----------------------------------------------------

  @doc """
  Make sure the active file exists and ends on a line boundary, cutting off a
  line torn by a crash. Returns its size.
  """
  def repair_active(path) do
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    size = File.stat!(path).size

    if size == 0 or last_byte(path, size) == "\n" do
      size
    else
      keep = last_newline(path, size)
      Logger.warning("ledger: cutting #{size - keep} bytes of a torn last line from #{Path.basename(path)}")
      {:ok, io} = :file.open(path, [:read, :write, :binary])
      {:ok, _} = :file.position(io, keep)
      :ok = :file.truncate(io)
      :ok = :file.datasync(io)
      :ok = :file.close(io)
      keep
    end
  end

  defp last_byte(path, size) do
    {:ok, io} = :file.open(path, [:read, :binary])
    {:ok, byte} = :file.pread(io, size - 1, 1)
    :file.close(io)
    byte
  end

  # Offset just after the last newline, searching backwards in blocks.
  defp last_newline(path, size) do
    {:ok, io} = :file.open(path, [:read, :binary])

    result =
      Stream.unfold(size, fn
        0 -> nil
        hi -> {{max(hi - 65_536, 0), hi}, max(hi - 65_536, 0)}
      end)
      |> Enum.find_value(0, fn {lo, hi} ->
        {:ok, block} = :file.pread(io, lo, hi - lo)

        case :binary.matches(block, "\n") do
          [] -> nil
          found -> lo + (found |> List.last() |> elem(0)) + 1
        end
      end)

    :file.close(io)
    result
  end

  @doc "Rename the active file to its numbered name and start an empty one. Returns the new active number."
  def seal(path) do
    seq = active_seq(path)
    :ok = seal_rename(path, seq)
    :ok = seal_create(path)
    seq + 1
  end

  @doc false
  def seal_rename(path, seq), do: File.rename!(path, sealed_path(path, seq))
  @doc false
  def seal_create(path), do: File.write!(path, "")

  @doc """
  Delete sealed segments numbered below `below_seq` whose last write is older
  than `cutoff_ms`, except the newest sealed one. Returns how many were deleted.
  """
  def delete_segments(path, below_seq, cutoff_ms) do
    # The newest sealed segment always stays: its number is what tells boot
    # which number the active segment has.
    candidates = path |> sealed() |> Enum.drop(-1)

    for {seq, file} <- candidates, seq < below_seq, modified_ms(file) < cutoff_ms, File.rm(file) == :ok, reduce: 0 do
      n -> n + 1
    end
  end

  defp modified_ms(file) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: seconds}} -> seconds * 1000
      _ -> :infinity
    end
  end

  # -- reading ---------------------------------------------------------------

  @doc """
  Where to read from to see every event after `covered` (`{seq, offset}`, or
  `nil` for everything): `[{file, offset}]` in order.
  """
  def tail(path, covered) do
    {from_seq, from_offset} = covered || {0, 0}
    segments = sealed(path) ++ [{active_seq(path), path}]

    for {seq, file} <- segments, seq >= from_seq, File.exists?(file) do
      {file, if(seq == from_seq, do: from_offset, else: 0)}
    end
  end

  @doc "Fold `fun.(event, acc)` over the events of `file` from byte `offset`. Unreadable lines are skipped."
  def fold(file, offset, acc, fun) do
    {:ok, io} = :file.open(file, [:read, :binary, :raw, {:read_ahead, 1_048_576}])
    {:ok, _} = :file.position(io, offset)
    result = fold_lines(io, acc, fun)
    :file.close(io)
    result
  end

  defp fold_lines(io, acc, fun) do
    case :file.read_line(io) do
      {:ok, line} ->
        acc =
          case String.trim(line) do
            "" ->
              acc

            text ->
              case JSON.decode(text) do
                {:ok, event} when is_map(event) ->
                  fun.(event, acc)

                _ ->
                  Logger.warning("ledger: skipping unreadable line during replay")
                  acc
              end
          end

        fold_lines(io, acc, fun)

      :eof ->
        acc
    end
  end

  @doc """
  One page of events for a reader outside the process, oldest first.

  `cursor` is a position `{segment, byte offset}` on a line boundary, or
  `nil` for the oldest event still on disk. `active` is `{seq, size}` of the
  active segment as the writer knows it, so a line being appended is never
  read. At most `limit` events for which `keep.(event)` holds are returned,
  and at most `max_bytes` are read: a page can be short, or empty, with more
  to come.

  Returns `{:ok, %{events: [{position_after, event}], next: position,
  gap: boolean, more: boolean}}`. `gap` is true when the cursor pointed into
  a segment that retention has deleted since: reading resumes at the oldest
  one left, and what lay between is gone. `{:error, :invalid_cursor}` for a
  position no cursor handed out could have.
  """
  def read_events(path, cursor, {active_seq, active_size}, limit, max_bytes, keep) do
    segments = for({seq, file} <- sealed(path), seq < active_seq, do: {seq, file, file_size(file)}) ++ [{active_seq, path, active_size}]
    {oldest, _, _} = hd(segments)

    {start, gap} =
      case cursor do
        nil -> {{oldest, 0}, false}
        {seq, _} when seq < oldest -> {{oldest, 0}, true}
        position -> {position, false}
      end

    case position_ok(segments, start) do
      true ->
        {events, next} = read_pages(Enum.drop_while(segments, fn {seq, _, _} -> seq < elem(start, 0) end), elem(start, 1), limit, max_bytes, keep, [])
        {last_seq, _, last_size} = List.last(segments)
        {:ok, %{events: Enum.reverse(events), next: next, gap: gap, more: next != {last_seq, last_size}}}

      false ->
        {:error, :invalid_cursor}
    end
  end

  defp file_size(file) do
    case File.stat(file) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # In a segment that exists, not past its end, and at the start of a line.
  defp position_ok(segments, {seq, offset}) do
    case Enum.find(segments, fn {s, _, _} -> s == seq end) do
      {_, file, size} when offset >= 0 and offset <= size -> offset == 0 or bytes_at(file, offset - 1, 1) == "
"
      _ -> false
    end
  end

  defp bytes_at(file, at, n) do
    case :file.open(file, [:read, :binary, :raw]) do
      {:ok, io} ->
        bytes = read_at(io, at, n)
        :file.close(io)
        bytes

      _ ->
        ""
    end
  end

  defp read_pages([{seq, file, size} | rest], offset, limit, budget, keep, acc) do
    chunk = bytes_at(file, offset, min(size - offset, budget))
    # Whole lines only: what follows the last newline is read next time.
    whole =
      case :binary.matches(chunk, "
") do
        [] -> 0
        matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
      end

    {acc, used, left} = take_lines(binary_part(chunk, 0, whole), seq, offset, limit, keep, acc)
    position = offset + used
    budget = budget - max(used, 1)

    cond do
      # The page is full, or nothing more may be read now.
      left == 0 or budget <= 0 ->
        {acc, normalize(seq, position, size, rest)}

      # This segment is read to its end: on to the next one.
      position >= size and rest != [] ->
        read_pages(rest, 0, left, budget, keep, acc)

      position >= size ->
        {acc, {seq, position}}

      # A megabyte without a line end is not an event (none is that long, by
      # far): step over it rather than stay in front of it forever.
      whole == 0 and byte_size(chunk) >= 1_048_576 ->
        read_pages([{seq, file, size} | rest], offset + byte_size(chunk), left, budget - byte_size(chunk), keep, acc)

      # What is left of this call's allowance ends inside a line.
      whole == 0 ->
        {acc, {seq, position}}

      true ->
        read_pages([{seq, file, size} | rest], position, left, budget, keep, acc)
    end
  end

  # The end of a sealed segment and the start of the next are the same place;
  # hand out the one that stays valid when the sealed one is deleted.
  defp normalize(seq, position, size, rest) do
    case rest do
      [{next_seq, _, _} | _] when position >= size -> {next_seq, 0}
      _ -> {seq, position}
    end
  end

  # Lines of `text` (all complete) from byte `offset` of segment `seq`, until
  # `limit` events are kept. Returns `{acc, bytes consumed, limit left}`.
  defp take_lines(text, seq, offset, limit, keep, acc), do: take_lines(text, seq, offset, 0, limit, keep, acc)

  defp take_lines(_text, _seq, _offset, used, 0, _keep, acc), do: {acc, used, 0}
  defp take_lines("", _seq, _offset, used, limit, _keep, acc), do: {acc, used, limit}

  defp take_lines(text, seq, offset, used, limit, keep, acc) do
    [line, rest] = :binary.split(text, "
")
    used = used + byte_size(line) + 1

    case JSON.decode(line) do
      {:ok, %{} = event} ->
        if keep.(event),
          do: take_lines(rest, seq, offset, used, limit - 1, keep, [{{seq, offset + used}, event} | acc]),
          else: take_lines(rest, seq, offset, used, limit, keep, acc)

      _ ->
        take_lines(rest, seq, offset, used, limit, keep, acc)
    end
  end

  # -- snapshots ---------------------------------------------------------------

  @doc "Fingerprint of the first and last bytes of `file` before `offset`."
  def fingerprint(file, offset) do
    {:ok, io} = :file.open(file, [:read, :binary])
    n = min(offset, @fingerprint_bytes)
    head = read_at(io, 0, n)
    tail = read_at(io, offset - n, n)
    :file.close(io)
    :crypto.hash(:sha256, [<<offset::64>>, head, tail])
  end

  defp read_at(_io, _at, 0), do: ""

  defp read_at(io, at, n) do
    case :file.pread(io, at, n) do
      {:ok, bytes} -> bytes
      _ -> ""
    end
  end

  @doc """
  Write `snapshot` (a map; `:covered` is `{seq, offset}` into the ledger at
  `path`) so that it replaces the current one atomically.
  """
  def write_snapshot(path, snapshot) do
    :ok = write_snapshot_tmp(path, snapshot)
    :ok = install_snapshot_step1(path)
    :ok = install_snapshot_step2(path)
  end

  @doc false
  def write_snapshot_tmp(path, %{covered: {seq, offset}} = snapshot) do
    file = file_of(path, seq)
    snapshot = Map.put(snapshot, :fingerprint, fingerprint(file, offset))
    payload = :erlang.term_to_binary(snapshot, compressed: 1)
    {:ok, io} = :file.open(tmp_path(path), [:write, :binary, :raw])
    :ok = :file.write(io, [@magic, :crypto.hash(:sha256, payload), payload])
    :ok = :file.datasync(io)
    :file.close(io)
  end

  @doc false
  def install_snapshot_step1(path) do
    if File.exists?(snapshot_path(path)), do: File.rename!(snapshot_path(path), prev_path(path))
    :ok
  end

  @doc false
  def install_snapshot_step2(path), do: File.rename!(tmp_path(path), snapshot_path(path))

  @doc """
  The newest usable snapshot: `{:ok, snapshot, :current | :prev}`, or `:none`.
  A snapshot that fails any check is reported in the log and skipped.
  """
  def load_snapshot(path) do
    Enum.find_value([{snapshot_path(path), :current}, {prev_path(path), :prev}], :none, fn {file, which} ->
      case read_snapshot(path, file) do
        {:ok, snapshot} ->
          {:ok, snapshot, which}

        :missing ->
          nil

        {:error, reason} ->
          Logger.warning("ledger: ignoring #{Path.basename(file)} (#{reason})")
          nil
      end
    end)
  end

  @doc "The segment a snapshot at `file` covers up to, without validating it against the ledger (or nil)."
  def covered_seq(file) do
    with {:ok, snapshot} <- decode_snapshot(file), %{covered: {seq, _}} <- snapshot, do: seq, else: (_ -> nil)
  end

  defp read_snapshot(path, file) do
    with {:ok, snapshot} <- decode_snapshot(file),
         :ok <- check_covers(path, snapshot) do
      {:ok, snapshot}
    end
  end

  defp decode_snapshot(file) do
    case File.read(file) do
      {:ok, <<@magic, sum::binary-size(32), payload::binary>>} ->
        if :crypto.hash(:sha256, payload) == sum do
          try do
            # `:safe` refuses anything that would create atoms or functions.
            # The checksum only catches accidents (it is not a signature), so
            # the decoded term is also checked row by row before any of it is
            # put into the tables: a file that does not look exactly like a
            # snapshot is ignored and the ledger is replayed instead.
            case :erlang.binary_to_term(payload, [:safe]) do
              # Version 1 carried the event ids themselves (`seen`); it is
              # still read, so an upgrade starts from its last snapshot.
              %{version: 1, covered: {seq, offset}, totals: t, seen: s} = snapshot
              when is_integer(seq) and seq >= 0 and is_integer(offset) and offset >= 0 and is_list(t) and is_list(s) ->
                if Enum.all?(t, &totals_row?/1) and Enum.all?(s, &seen_row?/1) and recent?(Map.get(snapshot, :recent, [])) do
                  {:ok, snapshot}
                else
                  {:error, "unexpected contents"}
                end

              # Version 2 records how long each day's id file was instead
              # (see `OmnigateControl.Ledger.Ids`).
              %{version: 2, covered: {seq, offset}, totals: t, ids: ids} = snapshot
              when is_integer(seq) and seq >= 0 and is_integer(offset) and offset >= 0 and is_list(t) and is_map(ids) ->
                if Enum.all?(t, &totals_row?/1) and Enum.all?(ids, &ids_row?/1) and recent?(Map.get(snapshot, :recent, [])) do
                  {:ok, snapshot}
                else
                  {:error, "unexpected contents"}
                end

              _ ->
                {:error, "unexpected contents"}
            end
          rescue
            _ -> {:error, "undecodable contents"}
          end
        else
          {:error, "checksum mismatch"}
        end

      {:ok, _} ->
        {:error, "not a ledger snapshot"}

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  defp totals_row?(row), do: is_tuple(row) and tuple_size(row) >= 2
  defp seen_row?({id, at}), do: is_binary(id) and is_integer(at)
  defp seen_row?(_), do: false
  defp ids_row?({day, bytes}), do: is_binary(day) and day =~ ~r/\A\d{4}-\d{2}-\d{2}\z/ and is_integer(bytes) and bytes >= 0
  defp ids_row?(_), do: false
  defp recent?(list), do: is_list(list) and Enum.all?(list, &is_map/1)

  # The bytes the snapshot covers must still exist and be the same bytes.
  defp check_covers(path, %{covered: {seq, offset}} = snapshot) do
    active = active_seq(path)
    sealed = sealed_path(path, seq)
    file = if seq == active, do: path, else: sealed

    cond do
      seq > active -> {:error, "covers segment #{seq}, but the ledger is at segment #{active}"}
      not File.exists?(file) -> {:error, "covers segment #{seq}, which is gone"}
      File.stat!(file).size < offset -> {:error, "covers #{offset} bytes of segment #{seq}, which is shorter"}
      fingerprint(file, offset) != snapshot[:fingerprint] -> {:error, "segment #{seq} is not the file it was taken from"}
      true -> :ok
    end
  end

  # A segment's file: its numbered name once sealed, the active file before.
  defp file_of(path, seq) do
    sealed = sealed_path(path, seq)
    if File.exists?(sealed), do: sealed, else: path
  end
end
