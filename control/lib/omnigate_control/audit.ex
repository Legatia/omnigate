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
    * `outcome`: `ok`, or the error type (`invalid_request`, `key_exists`,
      `denied`, `throttled`, ...)
    * `fields`: for `key.update`, the names of the fields that were sent

  Never a key, a token, a password or a webhook secret.

  The file only grows; rotate or archive it with your usual log tooling
  (the control plane reopens nothing, so restart it after moving the file).
  The newest entries are also kept in memory for `GET /admin/audit` and the
  dashboard.
  """
  use GenServer
  require Logger

  @keep 500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Record an action taken through `conn`. `extra` may carry `:auth` (to
  override what the connection shows, e.g. `"password"` for a login) and
  `:fields`.
  """
  def record(conn, action, target, outcome, extra \\ []) do
    entry =
      %{
        "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "action" => action,
        "target" => target,
        "auth" => extra[:auth] || auth(conn),
        "address" => address(conn.remote_ip),
        "outcome" => to_string(outcome)
      }
      |> put_if("forwarded_for", forwarded_for(conn))
      |> put_if("fields", extra[:fields])

    GenServer.call(__MODULE__, {:record, entry})
  end

  @doc "The newest entries, newest first."
  def recent(limit \\ 50) when is_integer(limit), do: GenServer.call(__MODULE__, {:recent, limit})

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    recent = tail(path)
    {:ok, %{file: File.open!(path, [:append, :binary]), path: path, recent: recent}}
  end

  @impl true
  def handle_call({:record, entry}, _from, state) do
    # An action that cannot be recorded is still carried out: refusing to
    # revoke a key because a disk is full would be worse. But say so loudly.
    with :ok <- IO.binwrite(state.file, [JSON.encode!(entry), ?\n]),
         :ok <- :file.datasync(state.file) do
      :ok
    else
      error -> Logger.error("audit log #{state.path} could not be written: #{inspect(error)}")
    end

    {:reply, :ok, %{state | recent: Enum.take([entry | state.recent], @keep)}}
  end

  def handle_call({:recent, limit}, _from, state) do
    {:reply, Enum.take(state.recent, limit |> max(0) |> min(@keep)), state}
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

  defp auth(conn) do
    cond do
      OmnigateControl.AdminAuth.bearer?(conn) -> "token"
      OmnigateControl.AdminAuth.session(conn) -> "session"
      true -> "none"
    end
  end

  defp address(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp address(_), do: nil

  defp forwarded_for(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] -> String.slice(value, 0, 200)
      [] -> nil
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
