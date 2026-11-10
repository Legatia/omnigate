defmodule OmnigateControl.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    OmnigateControl.AdminAuth.setup()
    ip = bind_address()

    children = [
      {OmnigateControl.ConfigStore, path: config_path()},
      {OmnigateControl.Ledger, path: ledger_path()},
      {OmnigateControl.Jobs.Store, path: jobs_path()},
      {Task.Supervisor, name: OmnigateControl.Jobs.TaskSup},
      OmnigateControl.Webhooks,
      # One-shot: continue jobs and webhooks left unfinished by the last run.
      Supervisor.child_spec({Task, &OmnigateControl.Jobs.resume_all/0}, id: :jobs_resume, restart: :temporary),
      OmnigateControl.Retention,
      {Bandit, plug: OmnigateControl.Router, ip: ip, port: port()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OmnigateControl.Supervisor)
  end

  defp config_path do
    System.get_env("OMNIGATE_CONFIG") ||
      Path.expand("../config/omnigate.dev.json", File.cwd!())
  end

  defp ledger_path do
    System.get_env("OMNIGATE_LEDGER") ||
      Application.get_env(:omnigate_control, :ledger_path) ||
      Path.expand("data/ledger.jsonl", File.cwd!())
  end

  defp jobs_path do
    System.get_env("OMNIGATE_JOBS") ||
      Application.get_env(:omnigate_control, :jobs_path) ||
      Path.expand("data/jobs.jsonl", File.cwd!())
  end

  # Loopback unless told otherwise. On any other address the dashboard and
  # the internal API are reachable from the network: both are authenticated,
  # but neither is encrypted, so put TLS in front.
  defp bind_address do
    text = System.get_env("OMNIGATE_CONTROL_BIND") || "127.0.0.1"

    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, ip} ->
        if ip not in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
          Logger.warning("control plane listening on #{text}: reachable from the network over plain HTTP; terminate TLS in front of it")
        end

        ip

      {:error, _} ->
        raise ArgumentError, "OMNIGATE_CONTROL_BIND is not an IP address: #{inspect(text)}"
    end
  end

  defp port do
    case System.get_env("OMNIGATE_CONTROL_PORT") do
      nil -> Application.get_env(:omnigate_control, :port, 4000)
      v -> String.to_integer(v)
    end
  end
end
