defmodule OmnigateControl.Application do
  @moduledoc false
  use Application
  require Logger

  # The development config ships in the repository: its gateway keys and
  # webhook secret are public, and it allows calls to private addresses. It
  # may stand in for a missing OMNIGATE_CONFIG only in a development or test
  # build, never in a release.
  @dev_build Mix.env() in [:dev, :test]

  @impl true
  def start(_type, _args) do
    with :ok <- check_internal_token(),
         :ok <- OmnigateControl.Env.check_all(),
         {:ok, _ip} <- bind_address(),
         {:ok, config} <- config_path(),
         :ok <- OmnigateControl.AdminAuth.setup() do
      start_children(config)
    else
      {:error, message} ->
        Logger.error(message)
        {:error, message}
    end
  end

  # Without it every data-plane call would be refused: better not to start
  # than to look healthy and serve nothing.
  defp check_internal_token do
    if is_nil(OmnigateControl.internal_token()) do
      {:error,
       "OMNIGATE_INTERNAL_TOKEN is not set (or is empty). It is the shared secret between the data plane and " <>
         "the control plane; set it to the same long random value for both, then start again."}
    else
      :ok
    end
  end

  defp start_children(config) do
    OmnigateControl.Rejections.setup()
    OmnigateControl.RateLimit.setup()
    {:ok, ip} = bind_address()

    children = [
      {OmnigateControl.ConfigStore, path: config},
      {OmnigateControl.Audit, path: audit_path()},
      {OmnigateControl.Keys, path: keys_path()},
      {OmnigateControl.Ledger, path: ledger_path()},
      {OmnigateControl.Jobs.Store, path: jobs_path()},
      {Task.Supervisor, name: OmnigateControl.Jobs.TaskSup},
      OmnigateControl.Webhooks,
      # One-shot: continue jobs and webhooks left unfinished by the last run.
      Supervisor.child_spec({Task, &OmnigateControl.Jobs.resume_all/0}, id: :jobs_resume, restart: :temporary),
      OmnigateControl.Retention,
      # HTTP/1.1 only: nothing here needs HTTP/2 or WebSockets, and every
      # protocol left on is one more parser in front of the authentication.
      {Bandit, plug: OmnigateControl.Router, ip: ip, port: port(), http_2_options: [enabled: false], websocket_options: [enabled: false]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OmnigateControl.Supervisor)
  end

  @doc false
  def config_path(env \\ System.get_env("OMNIGATE_CONFIG"), dev_build \\ @dev_build) do
    cond do
      is_binary(env) and env != "" ->
        {:ok, env}

      dev_build ->
        {:ok, Path.expand("../config/omnigate.dev.json", File.cwd!())}

      true ->
        {:error,
         "OMNIGATE_CONFIG is not set. Point it at your config file (see config/omnigate.example.json). " <>
           "The development config, with its published keys, is only used automatically in development builds."}
    end
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

        {:ok, ip}

      {:error, _} ->
        {:error, "OMNIGATE_CONTROL_BIND is not an IP address: #{inspect(text)}"}
    end
  end

  # Validated by `Env.check_all/0` before anything starts.
  defp port do
    {:ok, port} = OmnigateControl.Env.integer("OMNIGATE_CONTROL_PORT", Application.get_env(:omnigate_control, :port, 4000), 1..65_535)
    port
  end
end
