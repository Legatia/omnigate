defmodule OmnigateControl.Audit do
  @moduledoc """
  A record of what was done with admin access.

  Every state-changing admin action appends one JSON line to a file
  (`OMNIGATE_AUDIT_LOG`, default `data/audit.jsonl`) and is synced to disk
  before the action's response is sent:

      {"ts": "2026-11-10T18:02:11Z", "action": "key.create", "target": "my-app",
       "auth": "session", "address": "203.0.113.7", "outcome": "ok"}

    * `action`: `key.create`, `key.update`, `key.rotate`, `key.delete`,
      `login`, `logout`
    * `target`: the key name, or nil
    * `auth`: how the caller proved who they are: `token` (the admin token as
      a bearer token), `session` (a dashboard session), `password` (a login
      attempt), or `none`
    * `address`: the peer address of the connection. Behind a reverse proxy
      that is the proxy; `forwarded_for` then carries what the proxy reported
      (which a direct caller could fake, so it is recorded, not trusted)
    * `outcome`: `ok`, or the `error.code` the caller was given
      (`invalid_request`, `key_exists`, ...); for a login, `ok`, `denied` or
      `throttled`
    * `fields`: for `key.update`, the names of the fields that were sent
    * `repeats`: only on a summary line, see below

  Never a key, a token, a password or a webhook secret.

  ## Attempts by people who are not signed in

  A failed or throttled login is something anyone can cause, as often as
  they like, so it must neither fill the log nor make an operator's own
  action wait behind it. `anonymous/4` therefore writes the first such
  attempt from an address in a minute as an ordinary line, without making
  its caller wait, and only counts the rest. When the minute is over, one
  summary line says how many more there were:

      {"ts": "2026-11-10T18:03:00Z", "action": "login", "auth": "password",
       "address": "203.0.113.7", "outcome": "denied", "repeats": 418}

  So an address costs at most two lines per minute and outcome, whatever it
  sends. The number of addresses followed at once is capped; beyond the cap
  attempts are counted together under the address `"(others)"`.

  ## Text from outside

  A header such as `X-Forwarded-For` is bytes the caller chose. Everything in
  an entry is made valid, single-line UTF-8 before it is encoded, and an
  entry that still cannot be written is reported in the log instead of
  stopping this process.

  The file is rotated by size: at `OMNIGATE_AUDIT_MAX_MB` (default 50, 0 =
  never) it becomes `audit.jsonl.1`, the previous `.1` becomes `.2`, and so
  on up to `.3`; the oldest is dropped. It is opened afresh for every entry,
  so it can also be moved or archived from outside without a restart.
  The newest entries are also kept in memory for `GET /admin/audit` and the
  dashboard.
  """
  use GenServer
  require Logger

  alias OmnigateControl.Text

  @keep 500
  # Rotated files kept next to the live one: audit.jsonl.1 (newest) to .3.
  @generations 3
  # Attempts by anonymous callers: {address, action, outcome, minute} => count.
  @anon :omnigate_audit_anonymous
  @max_anon_rows 2_000
  @flush_ms 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Create the table anonymous attempts are counted in. Call once at boot."
  def setup do
    if :ets.whereis(@anon) == :undefined do
      :ets.new(@anon, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc """
  Record an action taken through `conn`. `extra` may carry `:auth` (to
  override what the connection shows, e.g. `"password"` for a login),
  `:fields`, and `:privacy` (a key's privacy mode after the change, in a few
  words). Returns once the entry is on disk.
  """
  def record(conn, action, target, outcome, extra \\ []) do
    GenServer.call(__MODULE__, {:record, entry(conn, action, target, outcome, extra)})
  end

  @doc """
  Record something the gateway did by itself (a bonus credited, a payment
  settled): no caller, no address. Never waits for the log.
  """
  def system(action, target, outcome, extra \\ []) do
    entry =
      %{
        "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "action" => action,
        "target" => target,
        "auth" => "system",
        "address" => nil,
        "outcome" => to_string(outcome)
      }
      |> put_if("topup", extra[:topup])
      |> put_if("payment", extra[:payment])

    GenServer.cast(__MODULE__, {:record, entry})
  end

  @doc """
  Record something an anonymous caller did (a failed or throttled login).
  Never waits for the log: the first attempt per address, action and outcome
  in a minute is written in the background, later ones are only counted and
  appear as one summary line when the minute is over.
  """
  def anonymous(conn, action, outcome, extra \\ []) do
    now = System.os_time(:second)
    minute = div(now, 60)
    address = OmnigateControl.AdminAuth.client_address(conn) |> address()
    row = {address, action, to_string(outcome), minute}
    # Past the cap, new addresses share one row; ones already followed keep theirs.
    row = if :ets.member(@anon, row) or :ets.info(@anon, :size) < @max_anon_rows, do: row, else: {"(others)", action, to_string(outcome), minute}

    if :ets.update_counter(@anon, row, 1, {row, 0}) == 1 do
      entry = entry(conn, action, nil, outcome, extra)
      entry = if elem(row, 0) == "(others)", do: entry |> Map.put("address", "(others)") |> Map.drop(["peer", "forwarded_for"]), else: entry
      GenServer.cast(__MODULE__, {:record, entry})
    end

    :ok
  rescue
    # The table is missing (a test that runs without the application): fall
    # back to an ordinary entry rather than lose it.
    ArgumentError -> GenServer.cast(__MODULE__, {:record, entry(conn, action, nil, outcome, extra)})
  end

  @doc "Write the summary lines of the minutes that are over now (also runs by itself every few seconds)."
  def flush(now_s \\ System.os_time(:second)), do: GenServer.call(__MODULE__, {:flush, now_s})

  @doc "The newest entries, newest first."
  def recent(limit \\ 50) when is_integer(limit), do: GenServer.call(__MODULE__, {:recent, limit})

  # `address` means the same on every line, summary lines included: the
  # address the caller is counted under (`AdminAuth.client_address/1`: the
  # peer, or behind a trusted proxy the hop it reported; IPv6 by its /64).
  # `peer` is the other end of the connection, written only when it differs.
  defp entry(conn, action, target, outcome, extra) do
    peer = address(conn.remote_ip)
    counted = address(OmnigateControl.AdminAuth.client_address(conn)) || peer

    %{
      "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "action" => action,
      "target" => target,
      "auth" => extra[:auth] || auth(conn),
      "address" => counted,
      "outcome" => to_string(outcome)
    }
    |> put_if("peer", if(peer != counted, do: peer))
    |> put_if("forwarded_for", forwarded_for(conn))
    |> put_if("fields", extra[:fields])
    |> put_if("privacy", extra[:privacy])
    |> put_if("topup", extra[:topup])
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    recent = tail(path)
    # So that a clean stop reaches `terminate/2`, which writes the counts
    # that have no summary line yet.
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, %{path: path, recent: recent, max_bytes: max_bytes()}}
  end

  # `OMNIGATE_AUDIT_MAX_MB` (default 50). 0 turns rotation off.
  defp max_bytes do
    case Application.get_env(:omnigate_control, :audit_max_bytes) do
      n when is_integer(n) ->
        n

      _ ->
        # Checked at startup (`OmnigateControl.Env.check_all/0`), so a bad
        # value never gets this far; the fallback is for tests that start
        # this process on its own.
        case OmnigateControl.Env.number("OMNIGATE_AUDIT_MAX_MB", 50) do
          {:ok, mb} -> round(mb * 1_048_576)
          {:error, _} -> 50 * 1_048_576
        end
    end
  end

  # audit.jsonl -> .1 -> .2 -> .3; the oldest falls off.
  defp rotate(path) do
    File.rm(path <> ".#{@generations}")
    for n <- (@generations - 1)..1//-1, do: File.rename(path <> ".#{n}", path <> ".#{n + 1}")
    File.rename(path, path <> ".1")
  end

  @impl true
  def handle_call({:record, entry}, _from, state), do: {:reply, :ok, write(state, [entry], [:append, :sync])}

  def handle_call({:flush, now_s}, _from, state), do: {:reply, :ok, flush_anonymous(state, now_s)}

  def handle_call({:recent, limit}, _from, state) do
    {:reply, Enum.take(state.recent, limit |> max(0) |> min(@keep)), state}
  end

  # From `anonymous/4`: nobody is waiting, and nothing an operator did
  # depends on it, so it is not worth a sync of its own.
  @impl true
  def handle_cast({:record, entry}, state), do: {:noreply, write(state, [entry], [:append])}

  @impl true
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, flush_anonymous(state, System.os_time(:second))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A clean stop (the supervisor shutting down, `docker stop`): write the
  # summary lines of every minute counted so far, the running one included,
  # so the counts are not lost with the process. A kill or a crash of the
  # node still loses them.
  @impl true
  def terminate(_reason, state) do
    flush_anonymous(state, :all)
    :ok
  end

  # One summary line per row of a finished minute that saw more than the one
  # attempt already written. `:all` takes the running minute too (its line
  # is then stamped with the time of writing, not the minute's end).
  defp flush_anonymous(state, upto) do
    now_s = System.os_time(:second)
    minute = if upto == :all, do: div(now_s, 60) + 1, else: div(upto, 60)

    finished =
      try do
        :ets.select(@anon, [{{{:"$1", :"$2", :"$3", :"$4"}, :"$5"}, [{:<, :"$4", minute}], [{{:"$1", :"$2", :"$3", :"$4", :"$5"}}]}])
      rescue
        ArgumentError -> []
      end

    entries =
      for {address, action, outcome, at, count} <- Enum.sort_by(finished, &elem(&1, 3)) do
        :ets.delete(@anon, {address, action, outcome, at})

        if count > 1 do
          %{
            "ts" => DateTime.from_unix!(min((at + 1) * 60, max(now_s, at * 60))) |> DateTime.to_iso8601(),
            "action" => action,
            "target" => nil,
            "auth" => "password",
            "address" => address,
            "outcome" => outcome,
            "repeats" => count - 1
          }
        end
      end
      |> Enum.reject(&is_nil/1)

    if entries == [], do: state, else: write(state, entries, [:append, :sync])
  end

  # An action that cannot be recorded is still carried out: refusing to
  # revoke a key because a disk is full would be worse. But say so loudly.
  # The file is opened for each write (they are rare), so it can be moved
  # or rotated from outside at any time without this process holding on to
  # the old one. Nothing in here may raise: this process must outlive
  # whatever it is asked to write down.
  defp write(state, entries, modes) do
    entries = Enum.map(entries, &Text.clean/1)

    lines =
      for entry <- entries do
        try do
          JSON.encode!(entry) <> "\n"
        rescue
          e ->
            Logger.error("audit log: an entry could not be encoded and was not written: #{Text.line(Exception.message(e), 200)}")
            ""
        end
      end

    data = IO.iodata_to_binary(lines)

    if state.max_bytes > 0 do
      case File.stat(state.path) do
        {:ok, %{size: size}} when size + byte_size(data) > state.max_bytes -> rotate(state.path)
        _ -> :ok
      end
    end

    case File.write(state.path, data, modes) do
      :ok -> :ok
      error -> Logger.error("audit log #{state.path} could not be written: #{inspect(error)}")
    end

    %{state | recent: Enum.take(Enum.reverse(entries) ++ state.recent, @keep)}
  end

  # The last @keep readable lines of the file, newest first.
  defp tail(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce([], fn line, acc ->
        case JSON.decode(String.trim(line)) do
          {:ok, %{} = entry} -> Enum.take([entry | acc], @keep)
          _ -> acc
        end
      end)
    else
      []
    end
  end

  # -- what a connection tells us -----------------------------------------------

  # The router has already decided (`AdminAuth.authenticate/1`, behind the
  # throttle) and left the answer on the connection.
  defp auth(conn) do
    case Map.get(conn.assigns, :auth, :unknown) do
      :token -> "token"
      :session -> "session"
      :unknown -> if OmnigateControl.AdminAuth.session(conn), do: "session", else: "none"
      _ -> "none"
    end
  end

  defp address(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp address(_), do: nil

  defp forwarded_for(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] -> Text.line(binary_part(value, 0, min(byte_size(value), 400)), 200)
      [] -> nil
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
