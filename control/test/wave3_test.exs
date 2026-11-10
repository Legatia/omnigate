defmodule OmnigateControl.Wave3Test do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias OmnigateControl.{Admin, Audit, ConfigStore, Keys, Metrics, Router}

  @admin "test-admin-token-0123456789"

  defp call(conn), do: Router.call(conn, Router.init([]))
  defp json(conn), do: JSON.decode!(conn.resp_body)
  defp as_json(conn), do: put_req_header(conn, "content-type", "application/json")

  describe "error shapes" do
    test "a body that is not JSON is a 400 with the gateway's error object" do
      # Credentials are checked before the body is parsed, so each call carries its own.
      creds = fn
        "/internal" <> _ -> [{"x-omnigate-internal", OmnigateControl.internal_token()}]
        "/admin" <> _ -> [{"authorization", "Bearer test-admin-token-0123456789"}]
        _ -> []
      end

      for path <- ["/internal/v1/jobs", "/internal/usage/batch", "/admin/keys", "/login"] do
        conn = conn(:post, path, ~s({"model": "x", )) |> as_json()
        conn = Enum.reduce(creds.(path), conn, fn {k, v}, c -> put_req_header(c, k, v) end) |> call()
        assert conn.status == 400, path
        assert %{"error" => %{"type" => "invalid_json", "message" => message}} = json(conn)
        assert is_binary(message)
        assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      end
    end

    test "a body over the limit is a 413 in the same shape" do
      big = ~s({"x":") <> String.duplicate("a", 8_100_000) <> ~s("})
      conn = conn(:post, "/internal/usage/batch", big) |> as_json() |> put_req_header("x-omnigate-internal", OmnigateControl.internal_token()) |> call()
      assert conn.status == 413

      # Without credentials the body is never parsed at all.
      anonymous = conn(:post, "/internal/usage/batch", big) |> as_json() |> call()
      assert anonymous.status == 401
      assert %{"error" => %{"type" => "payload_too_large"}} = json(conn)
    end

    test "an unexpected failure is a 500 that names a request id and nothing else" do
      log =
        capture_log(fn ->
          conn = conn(:get, "/__test/raise") |> call()
          assert conn.status == 500
          assert %{"error" => %{"type" => "internal_error", "message" => message, "request_id" => id}} = json(conn)
          refute message =~ "secret detail"
          refute conn.resp_body =~ "secret detail"
          assert id =~ ~r/^[0-9a-f]{16}$/
          send(self(), {:id, id})
        end)

      assert_received {:id, id}
      # The log line carries the same id, and the detail the client was not given.
      assert log =~ id
      assert log =~ "secret detail"
    end

    test "unknown paths and a missing internal token use the error object too" do
      conn = conn(:get, "/no/such/thing") |> call()
      assert conn.status == 404
      assert %{"error" => %{"type" => "not_found"}} = json(conn)

      conn = conn(:get, "/internal/config") |> call()
      assert conn.status == 401
      assert %{"error" => %{"type" => "unauthorized"}} = json(conn)
    end
  end

  describe "readiness" do
    test "/readyz is 200 when config, ledger and job store are up, and needs no credentials" do
      assert Router.readiness() == :ok
      conn = conn(:get, "/readyz") |> call()
      assert conn.status == 200
      assert json(conn) == %{"status" => "ready"}
      assert (conn(:get, "/healthz") |> call()).status == 200
    end

    test "the ledger reports where it stands" do
      assert %{ready: true, writable: true, segment: segment, offset: offset} = OmnigateControl.Ledger.status()
      assert segment >= 1 and offset >= 0
    end
  end

  describe "a config-file key and a managed key with the same name" do
    setup do
      original = :persistent_term.get({ConfigStore, :config})

      on_exit(fn ->
        :persistent_term.put({ConfigStore, :config}, original)
        Keys.delete("clash-key")
        ConfigStore.warn_shadowed()
      end)

      {:ok, original: original}
    end

    test "the file wins, the managed key is shadowed and shown as such, and nothing is listed twice", %{original: original} do
      {:ok, _managed, raw} = Keys.create(%{"name" => "clash-key"})
      managed_hash = OmnigateControl.sha256_hex(raw)
      assert Keys.find_current(managed_hash)

      file_hash = OmnigateControl.sha256_hex("og-file-clash")
      [file_key] = ConfigStore.normalize(%{"keys" => [%{"name" => "clash-key", "key" => "og-file-clash"}]}).keys

      log =
        capture_log(fn ->
          :persistent_term.put({ConfigStore, :config}, %{original | keys: original.keys ++ [file_key]})
          ConfigStore.warn_shadowed()
          # Said once, not on every reload.
          ConfigStore.warn_shadowed()
        end)

      assert log =~ "clash-key"
      assert log =~ "shadowed"
      assert length(String.split(log, "shadowed")) == 2

      # One key by that name is in use: the file's.
      assert [%{key_sha256: ^file_hash}] = Enum.filter(ConfigStore.get().keys, &(&1.name == "clash-key"))
      assert Keys.find_current(file_hash)
      refute Keys.find_current(managed_hash)

      # The data-plane snapshot knows only the file key.
      hashes = for k <- Router.snapshot().keys, k.name == "clash-key", do: k.key_sha256
      assert hashes == [file_hash]

      # The admin view lists both, the managed one marked.
      views = Enum.filter(Admin.keys(), &(&1.name == "clash-key"))
      assert [%{source: "file", shadowed: false}, %{source: "managed", shadowed: true, state: "shadowed"}] = views

      # Metrics have one series per name.
      series = Metrics.render() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, ~s(omnigate_key_requests_total{key="clash-key"})))
      assert length(series) == 1

      # Deleting the managed key through the API clears it up.
      conn = conn(:delete, "/admin/keys/clash-key") |> put_req_header("authorization", "Bearer " <> @admin) |> call()
      assert conn.status == 200
      assert [%{source: "file"}] = Enum.filter(Admin.keys(), &(&1.name == "clash-key"))
    end
  end

  describe "audit log rotation" do
    setup do
      dir = Path.join(System.tmp_dir!(), "omnigate-audit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:omnigate_control, :audit_max_bytes, 400)

      on_exit(fn ->
        Application.delete_env(:omnigate_control, :audit_max_bytes)
        File.rm_rf(dir)
      end)

      {:ok, path: Path.join(dir, "audit.jsonl")}
    end

    defp entry(n), do: %{"ts" => "2026-11-10T00:00:00Z", "action" => "key.update", "target" => "k#{n}", "auth" => "token", "outcome" => "ok"}

    test "the file is rotated by size and a few generations are kept", %{path: path} do
      {:ok, pid} = GenServer.start(Audit, path: path)
      for n <- 1..60, do: :ok = GenServer.call(pid, {:record, entry(n)})

      assert File.stat!(path).size <= 400
      assert File.exists?(path <> ".1") and File.exists?(path <> ".2") and File.exists?(path <> ".3")
      refute File.exists?(path <> ".4")
      # Nothing is lost at a rotation boundary: the newest entries are contiguous across the files.
      targets = for f <- [path <> ".1", path], line <- File.stream!(f), do: JSON.decode!(line)["target"]
      assert List.last(targets) == "k60"
      assert targets == Enum.map((60 - length(targets) + 1)..60, &"k#{&1}")
      # The in-memory view is unaffected by rotation.
      assert [%{"target" => "k60"} | _] = GenServer.call(pid, {:recent, 5})
      GenServer.stop(pid)
    end

    test "the file can be moved away from outside and writing carries on in a new one", %{path: path} do
      {:ok, pid} = GenServer.start(Audit, path: path)
      :ok = GenServer.call(pid, {:record, entry(1)})
      File.rename!(path, path <> ".moved")
      :ok = GenServer.call(pid, {:record, entry(2)})
      assert File.read!(path) =~ "k2"
      refute File.read!(path) =~ "k1"
      assert File.read!(path <> ".moved") =~ "k1"
      GenServer.stop(pid)
    end
  end

  describe "dashboard times" do
    test "timestamps are machine-readable for the script and labelled UTC without it" do
      {:ok, _} =
        OmnigateControl.Ledger.record_batch([
          %{"id" => "w3-#{System.unique_integer([:positive])}", "key_sha256" => "nobody", "status" => 200, "ts_ms" => 1_794_300_000_000}
        ])

      conn = conn(:get, "/") |> put_req_header("authorization", "Bearer " <> @admin) |> call()
      assert conn.status == 200
      assert conn.resp_body =~ ~r/<time datetime="2026-11-\d\dT[0-9:.]+Z" data-local>2026-11-\d\d \d\d:\d\d:\d\d UTC<\/time>/
      assert conn.resp_body =~ "today (UTC)"
      assert conn.resp_body =~ "localTimes()"
    end
  end
end
