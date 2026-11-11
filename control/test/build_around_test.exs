defmodule OmnigateControl.BuildAroundTest do
  # What outside tools build on: top-ups by payment reference, the usage
  # feed, and the caller's tag on a request. Changes the shared key store,
  # so not alongside other tests.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{Audit, ConfigStore, Keys, Ledger, Router}
  alias OmnigateControl.Ledger.Files

  @admin "test-admin-token-0123456789"
  @moduletag :capture_log

  setup do
    original = :persistent_term.get({ConfigStore, :config})

    on_exit(fn ->
      for k <- Keys.managed(), do: Keys.delete(k.name)
      :persistent_term.put({ConfigStore, :config}, original)
    end)

    :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp admin(method, path, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = conn |> put_req_header("authorization", "Bearer " <> @admin) |> Router.call(Router.init([]))

    json =
      case JSON.decode(conn.resp_body || "") do
        {:ok, value} -> value
        _ -> nil
      end

    {conn.status, json}
  end

  defp prepaid(budget \\ 0) do
    name = unique("prepaid")
    {201, %{"key" => raw}} = admin(:post, "/admin/keys", %{"name" => name, "budget_usd" => budget})
    {name, raw}
  end

  defp budget(name), do: Enum.find(Keys.managed(), &(&1.name == name)).budget_usd

  defp restart_keys do
    pid = Process.whereis(Keys)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_until(fn -> is_pid(Process.whereis(Keys)) and Process.whereis(Keys) != pid end)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # ------------------------------------------------------------------ top-ups

  describe "POST /admin/keys/{name}/topup" do
    test "adds to a total budget, and unblocks a key that had spent it" do
      {name, _raw} = prepaid()
      assert {200, %{"keys" => keys}} = admin(:get, "/admin/keys")
      assert %{"state" => "blocked", "budget_usd" => +0.0} = Enum.find(keys, &(&1["name"] == name))

      ref = unique("tx")
      assert {200, %{"key" => key, "topup" => done}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 2.5, "reference" => ref})
      assert %{"name" => ^name, "budget_usd" => 2.5, "state" => "active", "blocked" => false} = key
      assert %{"reference" => ^ref, "key" => ^name, "amount_usd" => 2.5, "budget_usd" => 2.5, "replayed" => false, "at" => at} = done
      assert at =~ ~r/^\d{4}-\d{2}-\d{2}T/

      assert {200, %{"key" => %{"budget_usd" => 4.0}}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 1.5, "reference" => unique("tx")})
    end

    test "the same reference again credits nothing and answers with the first result" do
      {name, _} = prepaid(1)
      ref = "0x" <> String.duplicate("ab", 32)
      assert {200, %{"topup" => first}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 5, "reference" => ref})
      assert first["replayed"] == false and first["budget_usd"] == 6.0

      for _ <- 1..3 do
        assert {200, %{"key" => %{"budget_usd" => 6.0}, "topup" => again}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 5, "reference" => ref})
        assert again == %{first | "replayed" => true}
      end

      assert budget(name) == 6.0

      # The reference names one payment: another amount or another key is a
      # conflict, not a second credit.
      assert {409, %{"error" => %{"code" => "reference_conflict"}}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 6, "reference" => ref})
      {other, _} = prepaid(1)
      assert {409, %{"error" => %{"code" => "reference_conflict"}}} = admin(:post, "/admin/keys/#{other}/topup", %{"amount_usd" => 5, "reference" => ref})
      assert budget(name) == 6.0 and budget(other) == 1.0
    end

    test "references survive a restart of the key store, in the same file as the budget" do
      {name, _} = prepaid()
      ref = unique("restart")
      assert {200, _} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 3, "reference" => ref})

      path = Application.get_env(:omnigate_control, :keys_path)
      assert %{"topups" => [%{"reference" => ^ref, "key" => ^name, "amount_usd" => 3.0, "budget_usd" => 3.0} | _]} = path |> File.read!() |> JSON.decode!()
      refute File.exists?(path <> ".tmp")

      restart_keys()
      assert budget(name) == 3.0
      assert {200, %{"topup" => %{"replayed" => true}}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 3, "reference" => ref})
      assert budget(name) == 3.0
    end

    test "concurrent top-ups: every distinct reference counts once, however often it is sent" do
      {name, _} = prepaid()
      refs = for i <- 1..20, do: unique("c#{i}")

      # Each reference from three callers at once.
      (refs ++ refs ++ refs)
      |> Enum.shuffle()
      |> Task.async_stream(fn ref -> admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 1, "reference" => ref}) end,
        max_concurrency: 30,
        timeout: 30_000
      )
      |> Enum.each(fn {:ok, {status, _}} -> assert status == 200 end)

      assert budget(name) == 20.0
    end

    test "only a managed key with a total budget takes one" do
      unlimited = unique("unlimited")
      {201, _} = admin(:post, "/admin/keys", %{"name" => unlimited})

      assert {409, %{"error" => %{"code" => "not_prepaid", "message" => message}}} =
               admin(:post, "/admin/keys/#{unlimited}/topup", %{"amount_usd" => 1, "reference" => unique("r")})

      assert message =~ "budget_usd"

      monthly = unique("monthly")
      {201, _} = admin(:post, "/admin/keys", %{"name" => monthly, "budget_usd" => 10, "budget_period" => "monthly"})
      assert {409, %{"error" => %{"code" => "not_prepaid"}}} = admin(:post, "/admin/keys/#{monthly}/topup", %{"amount_usd" => 1, "reference" => unique("r")})
      assert budget(monthly) == 10.0

      assert {404, %{"error" => %{"code" => "key_not_found"}}} =
               admin(:post, "/admin/keys/#{unique("nobody")}/topup", %{"amount_usd" => 1, "reference" => unique("r")})

      file_key = hd(ConfigStore.file_keys()).name
      assert {409, %{"error" => %{"code" => "read_only_key"}}} = admin(:post, "/admin/keys/#{file_key}/topup", %{"amount_usd" => 1, "reference" => unique("r")})

      anonymous = conn(:post, "/admin/keys/x/topup", "{}") |> put_req_header("content-type", "application/json") |> Router.call(Router.init([]))
      assert anonymous.status == 401
    end

    test "amounts and references are checked, and a refused top-up changes nothing" do
      {name, _} = prepaid(1)
      ok_ref = unique("r")

      for body <- [
            %{"reference" => ok_ref},
            %{"amount_usd" => 0, "reference" => ok_ref},
            %{"amount_usd" => -5, "reference" => ok_ref},
            %{"amount_usd" => "5", "reference" => ok_ref},
            %{"amount_usd" => 1.0e10, "reference" => ok_ref},
            %{"amount_usd" => 1},
            %{"amount_usd" => 1, "reference" => ""},
            %{"amount_usd" => 1, "reference" => "two words"},
            %{"amount_usd" => 1, "reference" => "line\nbreak"},
            %{"amount_usd" => 1, "reference" => "café"},
            %{"amount_usd" => 1, "reference" => String.duplicate("r", 201)},
            %{"amount_usd" => 1, "reference" => 42}
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} = admin(:post, "/admin/keys/#{name}/topup", body)
      end

      assert budget(name) == 1.0
      # None of the refused calls used the reference up.
      assert {200, %{"topup" => %{"replayed" => false}}} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 1, "reference" => ok_ref})
    end

    test "each call is in the audit log: what was added, under which reference, and replays as such" do
      {name, _} = prepaid()
      ref = unique("audited")
      {200, _} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 7, "reference" => ref})
      {200, _} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 7, "reference" => ref})
      {409, _} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 8, "reference" => ref})

      # Newest first; found by target, since other tests audit too.
      entries = Audit.recent(200) |> Enum.filter(&(&1["action"] == "key.topup" and &1["target"] == name))
      assert [conflict, replay, first] = entries
      assert %{"outcome" => "ok", "topup" => %{"reference" => ^ref, "amount_usd" => 7.0, "budget_usd" => 7.0, "replayed" => false}} = first
      assert %{"outcome" => "ok", "topup" => %{"replayed" => true}} = replay
      assert %{"outcome" => "reference_conflict", "topup" => %{"reference" => ^ref, "amount_usd" => 8}} = conflict
    end
  end

  # ------------------------------------------------------------ the usage feed

  defp scratch_ledger(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "omnigate-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    n = System.unique_integer([:positive])

    defaults = [
      path: Path.join(dir, "ledger.jsonl"),
      name: nil,
      tables: {:"events_totals_#{n}", :"events_seen_#{n}"},
      snapshot_every: 1_000_000,
      segment_bytes: 1_000_000_000,
      tick_ms: 3_600_000
    ]

    {:ok, pid} = GenServer.start(Ledger, Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, defaults[:path]}
  end

  defp put(pid, range, key \\ "k1") do
    events =
      for i <- range,
          do: %{"id" => "ev-#{key}-#{i}", "key_sha256" => key, "status" => 200, "input_tokens" => i, "output_tokens" => 1, "ts_ms" => 1_794_300_000_000 + i}

    {:ok, %{accepted: n}} = GenServer.call(pid, {:record_batch, events, :text})
    assert n == Enum.count(range)
  end

  # Every page from `cursor` to the end, as `{ids, last cursor, gap seen}`.
  defp drain(pid, cursor, limit, keep \\ fn _ -> true end, acc \\ [], gap \\ false) do
    {:ok, page} = Ledger.events(cursor, limit, keep, pid)
    assert length(page.events) <= limit
    acc = acc ++ Enum.map(page.events, fn {_position, e} -> e["id"] end)
    if page.more, do: drain(pid, page.next, limit, keep, acc, gap or page.gap), else: {acc, page.next, gap or page.gap}
  end

  describe "the ledger read by cursor" do
    test "pages are in order, complete and without repeats, across segments and restarts" do
      {pid, path} = scratch_ledger()
      assert {:ok, %{events: [], more: false, gap: false, next: {1, 0}}} = Ledger.events(nil, 10, fn _ -> true end, pid)

      put(pid, 1..25)
      {:ok, 2} = Ledger.rotate(pid)
      put(pid, 26..40)
      {:ok, 3} = Ledger.rotate(pid)
      put(pid, 41..50)

      expected = for i <- 1..50, do: "ev-k1-#{i}"

      for limit <- [1, 7, 50, 1000] do
        assert {^expected, _, false} = drain(pid, nil, limit)
      end

      # A cursor taken mid-way continues exactly after its event, also when
      # the segment it points into has been sealed since, and after a restart.
      {:ok, %{events: first, next: next}} = Ledger.events(nil, 45, fn _ -> true end, pid)
      {position, %{"id" => "ev-k1-45"}} = List.last(first)
      assert position == next
      {:ok, 4} = Ledger.rotate(pid)
      put(pid, 51..55)
      rest = for i <- 46..55, do: "ev-k1-#{i}"
      assert {^rest, last, false} = drain(pid, next, 3)

      GenServer.stop(pid)
      n = System.unique_integer([:positive])

      {:ok, again} =
        GenServer.start(Ledger,
          path: path,
          name: nil,
          tables: {:"events_totals_#{n}", :"events_seen_#{n}"},
          snapshot_every: 1_000_000,
          segment_bytes: 1_000_000_000,
          tick_ms: 3_600_000
        )

      on_exit(fn -> if Process.alive?(again), do: GenServer.stop(again) end)
      assert {^rest, ^last, false} = drain(again, next, 4)
      # At the end: nothing, and the same cursor, until something is recorded.
      assert {:ok, %{events: [], more: false, next: ^last}} = Ledger.events(last, 10, fn _ -> true end, again)
      put(again, 56..56)
      assert {["ev-k1-56"], _, false} = drain(again, last, 10)
    end

    test "a filter skips other events without losing the place" do
      {pid, _} = scratch_ledger()
      put(pid, 1..30, "a")
      put(pid, 1..5, "b")
      put(pid, 31..60, "a")
      put(pid, 6..10, "b")

      only_b = fn e -> e["key_sha256"] == "b" end
      expected = for i <- 1..10, do: "ev-b-#{i}"
      assert {^expected, _, false} = drain(pid, nil, 3, only_b)
      assert {[], _, false} = drain(pid, nil, 3, fn _ -> false end)
    end

    test "segments deleted by retention: the cursor resumes at the oldest left and says so" do
      {pid, path} = scratch_ledger()
      put(pid, 1..10)
      {:ok, %{next: early}} = Ledger.events(nil, 4, fn _ -> true end, pid)
      {:ok, 2} = Ledger.rotate(pid)
      put(pid, 11..20)
      {:ok, 3} = Ledger.rotate(pid)
      put(pid, 21..30)

      assert Ledger.prune_segments(System.os_time(:millisecond) + 86_400_000, pid) == 1
      assert [{2, _}] = Files.sealed(path)

      survivors = for i <- 11..30, do: "ev-k1-#{i}"
      assert {:ok, %{gap: true}} = Ledger.events(early, 5, fn _ -> true end, pid)
      assert {^survivors, _, true} = drain(pid, early, 6)
      # A reader that starts now is told nothing is missing: it had no place to lose.
      assert {^survivors, _, false} = drain(pid, nil, 6)
    end

    test "a position no cursor could have is refused" do
      {pid, _} = scratch_ledger()
      put(pid, 1..5)
      {:ok, %{events: [{{1, first_end}, _} | _], next: {1, size}}} = Ledger.events(nil, 10, fn _ -> true end, pid)

      for bad <- [{1, first_end - 3}, {1, size + 1}, {2, 0}, {9, 0}, {1, 1}] do
        assert {:error, :invalid_cursor} = Ledger.events(bad, 10, fn _ -> true end, pid)
      end

      assert {:ok, _} = Ledger.events({1, first_end}, 10, fn _ -> true end, pid)
    end

    test "a line that is not an event is stepped over" do
      {pid, path} = scratch_ledger()
      put(pid, 1..2)
      GenServer.stop(pid)
      File.write!(path, "not json\n\n[1,2]\n", [:append])
      n = System.unique_integer([:positive])

      {:ok, again} =
        GenServer.start(Ledger,
          path: path,
          name: nil,
          tables: {:"events_totals_#{n}", :"events_seen_#{n}"},
          snapshot_every: 1_000_000,
          segment_bytes: 1_000_000_000,
          tick_ms: 3_600_000
        )

      on_exit(fn -> if Process.alive?(again), do: GenServer.stop(again) end)
      put(again, 3..4)
      assert {["ev-k1-1", "ev-k1-2", "ev-k1-3", "ev-k1-4"], _, false} = drain(again, nil, 10)
    end
  end

  describe "GET /admin/events" do
    test "text requests and media jobs, by key name, with a tag, and never a hash or content" do
      {name, raw} = prepaid(100)
      hash = OmnigateControl.sha256_hex(raw)
      {200, %{"next" => start}} = admin(:get, "/admin/events?limit=1000")
      start = drain_http(start)

      id = unique("req")

      {:ok, %{accepted: 3}} =
        Ledger.record_batch([
          %{
            "id" => id,
            "key_sha256" => hash,
            "status" => 200,
            "stream" => true,
            "input_tokens" => 12,
            "output_tokens" => 3,
            "tag" => "tenant-7",
            "ts_ms" => System.os_time(:millisecond)
          },
          # A tag the data plane would never have let through is not kept.
          %{"id" => id <> "-b", "key_sha256" => hash, "status" => 200, "input_tokens" => 1, "output_tokens" => 1, "tag" => "two words"},
          %{"id" => id <> "-c", "key_sha256" => "someone-else", "status" => 200, "input_tokens" => 1, "output_tokens" => 1, "tag" => nil}
        ])

      {:ok, _} =
        Ledger.record_media(%{
          "id" => id <> "-job",
          "key_sha256" => hash,
          "route_model" => "img",
          "upstream" => "prov",
          "status" => 200,
          "cost_usd" => 0.25,
          "outputs" => 2
        })

      assert {200, %{"events" => events, "more" => false, "gap" => false, "next" => next}} = admin(:get, "/admin/events?after=#{start}&key=#{name}")
      assert [text, untagged, job] = events

      assert %{
               "id" => ^id,
               "kind" => "text",
               "key" => ^name,
               "tag" => "tenant-7",
               "status" => 200,
               "stream" => true,
               "input_tokens" => 12,
               "output_tokens" => 3,
               "cursor" => c1
             } = text

      assert text["ts"] =~ ~r/^\d{4}-/ and text["received_at"] =~ ~r/^\d{4}-/
      assert %{"tag" => nil, "kind" => "text"} = untagged
      assert %{"kind" => "media", "model" => "img", "upstream" => "prov", "cost_usd" => 0.25, "outputs" => 2, "tag" => nil} = job
      refute JSON.encode!(events) =~ hash

      # Each event's cursor continues after it; the page's `next` after the last.
      assert {200, %{"events" => [^untagged, ^job]}} = admin(:get, "/admin/events?after=#{c1}&key=#{name}")
      assert {200, %{"events" => [], "next" => ^next}} = admin(:get, "/admin/events?after=#{next}&key=#{name}")
      # Without the filter the other key's event is there too, under no name.
      assert {200, %{"events" => all}} = admin(:get, "/admin/events?after=#{start}&limit=1000")
      assert %{"key" => nil} = Enum.find(all, &(&1["id"] == id <> "-c"))

      # After the key is deleted its events stay, without a name.
      {200, _} = admin(:delete, "/admin/keys/#{name}")
      assert {200, %{"events" => after_delete}} = admin(:get, "/admin/events?after=#{start}&limit=1000")
      assert %{"key" => nil, "tag" => "tenant-7"} = Enum.find(after_delete, &(&1["id"] == id))
      assert {404, %{"error" => %{"code" => "key_not_found"}}} = admin(:get, "/admin/events?key=#{name}")
    end

    test "limits, bad cursors and who may read" do
      assert {200, %{"events" => events}} = admin(:get, "/admin/events?limit=0")
      assert length(events) <= 1

      for bad <- ["x", "1", "1-", "-1", "1-2-3", "1.0-0", "99999999-0", "1-999999999999"] do
        assert {400, %{"error" => %{"code" => "invalid_cursor"}}} = admin(:get, "/admin/events?after=#{bad}")
      end

      assert Router.call(conn(:get, "/admin/events"), Router.init([])).status == 401
    end
  end

  # Read the application's feed to its end; the cursor there.
  defp drain_http(cursor) do
    case admin(:get, "/admin/events?after=#{cursor}&limit=1000") do
      {200, %{"more" => true, "next" => next}} -> drain_http(next)
      {200, %{"next" => next}} -> next
    end
  end
end
