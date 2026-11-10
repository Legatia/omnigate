defmodule OmnigateControl.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Without it every data-plane call would be refused: better not to start
    # than to look healthy and serve nothing.
    if is_nil(OmnigateControl.internal_token()) do
      message =
        "OMNIGATE_INTERNAL_TOKEN is not set (or is empty). It is the shared secret between the data plane and " <>
          "the control plane; set it to the same long random value for both, then start again."

      Logger.error(message)
      {:error, message}
    else
      start_children()
    end
  end

  defp start_children do
    OmnigateControl.AdminAuth.setup()
    OmnigateControl.Rejections.setup()
    ip = bind_address()

    children = [
      {OmnigateControl.ConfigStore, path: config_path()},
      {OmnigateControl.Audit, path: audit_path()},
      {OmnigateControl.Keys, path: keys_path()},
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

  defp keys_path do
    System.get_env("OMNIGATE_KEYS") ||
      Application.get_env(:omnigate_control, :keys_path) ||
      Path.expand("data/keys.json", File.cwd!())
  end

  defp audit_path do
    System.get_env("OMNIGATE_AUDIT_LOG") ||
      Application.get_env(:omnigate_control, :audit_path) ||
      Path.expand("data/audit.jsonl", File.cwd!())
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
