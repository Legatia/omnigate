defmodule OmnigateControl.LedgerSnapshotTest do
  @moduledoc """
  The ledger's snapshots, segments and rotation, including what a crash at
  each step leaves on disk. Every scenario ends the same way: a ledger booted
  from the files has exactly the totals of a ledger that never stopped.

  These run private ledger processes on scratch directories (`name: nil`,
  their own tables), next to the application's ledger.
  """
  use ExUnit.Case, async: false

  alias OmnigateControl.Ledger
  alias OmnigateControl.Ledger.Files

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "omnigate-ledger-snap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "ledger.jsonl")}
  end

  # -- helpers ---------------------------------------------------------------

  defp boot(path, opts \\ []) do
    n = System.unique_integer([:positive])
    tables = {:"ledger_snap_totals_#{n}", :"ledger_snap_seen_#{n}"}
    # Far-off timers and thresholds: the tests decide when things happen.
    defaults = [path: path, name: nil, tables: tables, snapshot_every: 1_000_000, segment_bytes: 1_000_000_000, tick_ms: 3_600_000]
    {:ok, pid} = GenServer.start(Ledger, Keyword.merge(defaults, opts))
    pid
  end

  # A crash: no terminate/2, so no parting snapshot.
  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    :ok
  end

  defp stop(pid), do: GenServer.stop(pid)

  defp events(range, key \\ "k1") do
    for i <- range do
      %{
        "id" => "ev-#{key}-#{i}",
        "key_sha256" => key,
        "status" => if(rem(i, 7) == 0, do: 500, else: 200),
        "input_tokens" => 10 + i,
        "output_tokens" => i,
        # No route/upstream: the cost of text events would depend on the
        # application's config, so the cost comes from media-style events.
        "ts_ms" => 1_794_300_000_000 + i * 60_000
      }
    end
  end

  defp record(pid, range, key \\ "k1") do
    {:ok, %{accepted: n}} = GenServer.call(pid, {:record_batch, events(range, key), :text})
    assert n == Enum.count(range)

    for i <- range do
      {:ok, _} =
        GenServer.call(
          pid,
          {:record_batch,
           [%{"id" => "job-#{key}-#{i}", "key_sha256" => key, "status" => 200, "cost_usd" => 0.001 * i + 0.1, "ts_ms" => 1_794_300_000_000 + i * 60_000}],
           :media}
        )
    end

    :ok
  end

  # What a ledger that never stopped holds after the same events.
  defp reference(dir, ranges) do
    pid = boot(Path.join([dir, "reference", "ledger.jsonl"]))
    Enum.each(ranges, fn {range, key} -> record(pid, range, key) end)
    dump = Ledger.dump(pid)
    stop(pid)
    dump
  end

  defp assert_same(pid, expected) do
    got = Ledger.dump(pid)
    assert got.totals == expected.totals
    assert got.ids == expected.ids
  end

  # -- the plain cases ---------------------------------------------------------

  test "an old single-file ledger upgrades in place and leaves a snapshot", %{dir: dir, path: path} do
    expected = reference(dir, [{1..30, "k1"}, {1..10, "k2"}])

    # Exactly what an earlier version left behind: one file, nothing else.
    File.cp!(Path.join([dir, "reference", "ledger.jsonl"]), path)
    refute File.exists?(Files.snapshot_path(path))

    pid = boot(path)
    assert_same(pid, expected)
    assert File.exists?(Files.snapshot_path(path))
    assert Ledger.status(pid).segment == 1
    kill(pid)

    # The second boot comes from the snapshot and replays nothing.
    assert {:ok, snapshot, :current} = Files.load_snapshot(path)
    assert snapshot.covered == {1, File.stat!(path).size}
    pid = boot(path)
    assert_same(pid, expected)
    stop(pid)
  end

  test "a restart after a snapshot plus later events gives the same totals", %{dir: dir, path: path} do
    expected = reference(dir, [{1..20, "k1"}, {21..45, "k1"}, {1..5, "k2"}])

    pid = boot(path)
    record(pid, 1..20)
    assert :ok = Ledger.snapshot(pid)
    record(pid, 21..45)
    record(pid, 1..5, "k2")
    kill(pid)

    pid = boot(path)
    assert_same(pid, expected)
    # Duplicates are still recognised after the restart, old and new alike.
    assert {:ok, %{accepted: 0, duplicates: 3}} = GenServer.call(pid, {:record_batch, events([1, 20, 45]), :text})
    stop(pid)
  end

  test "a clean stop writes a snapshot that covers everything", %{path: path} do
    pid = boot(path)
    record(pid, 1..12)
    stop(pid)
    assert {:ok, snapshot, :current} = Files.load_snapshot(path)
    assert snapshot.covered == {1, File.stat!(path).size}
  end

  test "snapshots are taken every N events and segments sealed by size", %{dir: dir, path: path} do
    expected = reference(dir, [{1..40, "k1"}])

    pid = boot(path, snapshot_every: 10, segment_bytes: 4_000)
    record(pid, 1..40)
    status = Ledger.status(pid)
    assert status.segment > 2
    assert status.events_since_snapshot < 10
    assert length(Files.sealed(path)) == status.segment - 1
    kill(pid)

    pid = boot(path)
    assert_same(pid, expected)
    stop(pid)
  end

  # -- damaged or mismatched snapshots ------------------------------------------

  test "a corrupted snapshot is ignored in favour of the spare, then of a full replay", %{dir: dir, path: path} do
    expected = reference(dir, [{1..10, "k1"}, {11..20, "k1"}, {21..30, "k1"}])

    pid = boot(path)
    record(pid, 1..10)
    :ok = Ledger.snapshot(pid)
    record(pid, 11..20)
    :ok = Ledger.snapshot(pid)
    record(pid, 21..30)
    kill(pid)

    flip = fn file ->
      <<head::binary-size(60), byte, rest::binary>> = File.read!(file)
      File.write!(file, <<head::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>)
    end

    flip.(Files.snapshot_path(path))
    assert {:ok, _, :prev} = Files.load_snapshot(path)
    pid = boot(path)
    assert_same(pid, expected)
    kill(pid)

    # Both damaged: the events are all still in the file.
    flip.(Files.snapshot_path(path))
    if File.exists?(Files.prev_path(path)), do: flip.(Files.prev_path(path))
    File.write!(Files.snapshot_path(path), "not a snapshot at all")
    pid = boot(path)
    assert_same(pid, expected)
    stop(pid)
  end

  test "a snapshot of a different or shortened ledger file is not trusted", %{dir: dir, path: path} do
    pid = boot(path)
    record(pid, 1..10)
    stop(pid)
    snapshot = File.read!(Files.snapshot_path(path))

    # Another ledger's file under the same name, same length or longer.
    other = Path.join([dir, "other", "ledger.jsonl"])
    pid = boot(other)
    record(pid, 1..15, "someone-else")
    expected = Ledger.dump(pid)
    stop(pid)

    File.cp!(other, path)
    File.write!(Files.snapshot_path(path), snapshot)
    File.rm(Files.prev_path(path))
    assert :none = Files.load_snapshot(path)
    pid = boot(path)
    assert_same(pid, expected)
    kill(pid)

    # The right file, but cut short: the snapshot covers bytes that are gone.
    File.write!(path, binary_part(File.read!(path), 0, 200) |> String.replace(~r/[^\n]*\z/, ""))
    File.write!(Files.snapshot_path(path), snapshot)
    File.rm(Files.prev_path(path))
    assert :none = Files.load_snapshot(path)
  end

  test "a torn last line is cut off before anything is appended after it", %{dir: dir, path: path} do
    expected = reference(dir, [{1..10, "k1"}, {11..12, "k1"}])

    pid = boot(path)
    record(pid, 1..10)
    kill(pid)
    File.write!(path, ~s({"id":"torn","key_sha256":"k1","status":200,"input_to), [:append])

    pid = boot(path)
    record(pid, 11..12)
    kill(pid)

    pid = boot(path)
    assert_same(pid, expected)
    refute File.read!(path) =~ "torn"
    stop(pid)
  end

  # -- a crash at each step of taking a snapshot ----------------------------------

  test "crash at every step of writing a snapshot", %{dir: dir, path: path} do
    expected = reference(dir, [{1..10, "k1"}, {11..20, "k1"}])

    for step <- [:tmp_written, :old_moved_aside, :installed] do
      File.rm_rf!(dir |> Path.join("crash"))
      path = Path.join([dir, "crash", "ledger.jsonl"])
      pid = boot(path)
      record(pid, 1..10)
      :ok = Ledger.snapshot(pid)
      record(pid, 11..20)
      state = :sys.get_state(pid)
      totals = Ledger.dump(pid)
      kill(pid)

      # Redo the next snapshot by hand, stopping where the crash happens.
      snapshot = %{version: 2, covered: {state.segment, state.offset}, totals: totals.totals, ids: Ledger.Ids.sizes(state.ids), recent: [], taken_ms: 0}
      :ok = Files.write_snapshot_tmp(path, snapshot)
      if step in [:old_moved_aside, :installed], do: :ok = Files.install_snapshot_step1(path)
      if step == :installed, do: :ok = Files.install_snapshot_step2(path)

      which = if step == :installed, do: :current, else: if(step == :old_moved_aside, do: :prev, else: :current)
      assert {:ok, _, ^which} = Files.load_snapshot(path)

      pid = boot(path)
      assert_same(pid, expected)
      stop(pid)
    end

    _ = path
  end

  # -- a crash at each step of sealing a segment -----------------------------------

  test "crash at every step of sealing a segment", %{dir: dir} do
    expected = reference(dir, [{1..10, "k1"}, {11..20, "k1"}, {21..25, "k1"}])

    for step <- [:renamed, :created, :snapshotted] do
      File.rm_rf!(Path.join(dir, "seal"))
      path = Path.join([dir, "seal", "ledger.jsonl"])
      pid = boot(path)
      record(pid, 1..10)
      :ok = Ledger.snapshot(pid)
      # After this, the newest snapshot points into the middle of segment 1.
      record(pid, 11..20)
      kill(pid)

      :ok = Files.seal_rename(path, 1)
      if step in [:created, :snapshotted], do: :ok = Files.seal_create(path)

      pid = boot(path)
      assert Ledger.status(pid).segment == 2
      if step == :snapshotted, do: :ok = Ledger.snapshot(pid)
      record(pid, 21..25)
      kill(pid)

      pid = boot(path)
      assert_same(pid, expected)
      stop(pid)
    end
  end

  # -- rotation and deletion --------------------------------------------------------

  test "deleting old segments keeps every total, across restarts and crashes", %{dir: dir, path: path} do
    expected = reference(dir, [{1..10, "k1"}, {11..20, "k1"}, {1..8, "k2"}, {21..30, "k1"}])
    far_future = System.os_time(:millisecond) + 86_400_000

    pid = boot(path)
    record(pid, 1..10)
    {:ok, 2} = Ledger.rotate(pid)
    record(pid, 11..20)
    record(pid, 1..8, "k2")
    {:ok, 3} = Ledger.rotate(pid)
    record(pid, 21..30)

    # Nothing is deleted on the strength of a single snapshot generation...
    assert [{1, _}, {2, _}] = Files.sealed(path)
    # ...both generations now cover segments 1 and 2 (two rotations, each with
    # a snapshot). The newest sealed segment stays as the numbering anchor.
    assert Ledger.prune_segments(far_future, pid) == 1
    assert [{2, _}] = Files.sealed(path)
    assert_same(pid, expected)
    kill(pid)

    # After a crash: from the snapshot, plus what was written after it.
    pid = boot(path)
    assert_same(pid, expected)
    assert Ledger.status(pid).segment == 3
    kill(pid)

    # The newest snapshot is lost: the spare alone still has every total.
    File.rm!(Files.snapshot_path(path))
    assert {:ok, _, :prev} = Files.load_snapshot(path)
    pid = boot(path)
    assert_same(pid, expected)
    stop(pid)
  end

  test "a segment that is not old enough, or not covered twice, stays", %{path: path} do
    future = System.os_time(:millisecond) + 86_400_000
    pid = boot(path)
    record(pid, 1..5)
    {:ok, 2} = Ledger.rotate(pid)
    # The only sealed segment is the numbering anchor and never goes.
    record(pid, 6..7)
    :ok = Ledger.snapshot(pid)
    assert Ledger.prune_segments(future, pid) == 0

    record(pid, 8..10)
    {:ok, 3} = Ledger.rotate(pid)
    # Segment 1 is covered by both generations (the snapshot above and the one
    # the rotation took), but was written a moment ago: too young for this cutoff.
    assert Ledger.prune_segments(System.os_time(:millisecond) - 3_600_000, pid) == 0
    assert [{1, _}, {2, _}] = Files.sealed(path)
    assert Ledger.prune_segments(future, pid) == 1
    assert [{2, _}] = Files.sealed(path)
    stop(pid)

    # A fresh boot vouches for the one snapshot it read; with the next one it
    # writes there are two generations again, and both cover segment 2.
    pid = boot(path)
    assert Ledger.prune_segments(future, pid) == 0
    record(pid, 11..12)
    {:ok, 4} = Ledger.rotate(pid)
    assert Ledger.prune_segments(future, pid) == 1
    assert [{3, _}] = Files.sealed(path)
    stop(pid)
  end

  test "a restart on a quiet system can still delete due segments", %{dir: dir, path: path} do
    future = System.os_time(:millisecond) + 86_400_000
    pid = boot(path)
    record(pid, 1..4)
    {:ok, 2} = Ledger.rotate(pid)
    record(pid, 5..8)
    {:ok, 3} = Ledger.rotate(pid)
    assert [{1, _}, {2, _}] = Files.sealed(path)
    stop(pid)

    # Nothing is recorded after this boot: no event, so no snapshot by itself.
    pid = boot(path)
    assert Ledger.prune_segments(future, pid) == 1
    assert [{2, _}] = Files.sealed(path)
    expected = reference(dir, [{1..4, "k1"}, {5..8, "k1"}])
    assert_same(pid, expected)
    stop(pid)

    # And the totals survive another restart, and a crash right after it.
    pid = boot(path)
    assert_same(pid, expected)
    kill(pid)
    pid = boot(path)
    assert_same(pid, expected)
    stop(pid)
  end

  test "a crash part-way through deleting segments changes nothing", %{dir: dir, path: path} do
    expected = reference(dir, [{1..6, "k1"}, {7..12, "k1"}, {13..18, "k1"}, {19..24, "k1"}])

    pid = boot(path)
    record(pid, 1..6)
    {:ok, _} = Ledger.rotate(pid)
    record(pid, 7..12)
    {:ok, _} = Ledger.rotate(pid)
    record(pid, 13..18)
    {:ok, _} = Ledger.rotate(pid)
    record(pid, 19..24)
    :ok = Ledger.snapshot(pid)
    kill(pid)

    # Only the first of three eligible segments got deleted before the crash.
    [{1, first} | _] = Files.sealed(path)
    File.rm!(first)

    pid = boot(path)
    assert_same(pid, expected)
    stop(pid)
  end

  test "with segments deleted and no snapshot left, boot rebuilds from what remains and says so", %{path: path} do
    pid = boot(path)
    record(pid, 1..5)
    {:ok, _} = Ledger.rotate(pid)
    record(pid, 6..10)
    {:ok, _} = Ledger.rotate(pid)
    assert Ledger.prune_segments(System.os_time(:millisecond) + 86_400_000, pid) >= 1
    kill(pid)

    File.rm(Files.snapshot_path(path))
    File.rm(Files.prev_path(path))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = boot(path)
        stop(pid)
      end)

    assert log =~ "spend recorded before them is lost"
  end

  test "the application's own ledger comes back from its snapshot after a restart" do
    key = "restart-#{System.unique_integer([:positive])}"
    {:ok, %{accepted: 20}} = Ledger.record_batch(events(1..20, key))
    {:ok, _} = Ledger.record_media(%{"id" => "job-#{key}", "key_sha256" => key, "status" => 200, "cost_usd" => 1.25})
    before = {Ledger.totals(key), Ledger.grand_totals(), Ledger.period_spend(key, "monthly"), hd(Ledger.recent())["id"]}

    # A clean stop (terminate/2 runs), then the supervisor starts it again.
    :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Ledger)
    {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Ledger)

    assert {Ledger.totals(key), Ledger.grand_totals(), Ledger.period_spend(key, "monthly"), hd(Ledger.recent())["id"]} == before
    assert %{ready: true, events_since_snapshot: 0} = Ledger.status()
    assert {:ok, %{accepted: 0, duplicates: 1}} = Ledger.record_batch(events([7], key))

    # A crash instead: nothing but the files, including events after the snapshot.
    {:ok, %{accepted: 5}} = Ledger.record_batch(events(21..25, key))
    after_more = Ledger.totals(key)
    pid = Process.whereis(Ledger)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert wait_for(fn -> match?(%{ready: true}, Ledger.status()) end)
    assert Ledger.totals(key) == after_more
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        wait_for(fun, tries - 1)
    end
  end

  test "the daily tick seals a segment from an earlier day", %{path: path} do
    pid = boot(path)
    record(pid, 1..3)
    :sys.replace_state(pid, &%{&1 | segment_day: "2020-01-01"})
    send(pid, :tick)
    assert Ledger.status(pid).segment == 2
    assert [{1, _}] = Files.sealed(path)
    stop(pid)
  end
end
