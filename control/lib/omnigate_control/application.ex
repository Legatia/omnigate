defmodule OmnigateControl.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {OmnigateControl.ConfigStore, path: config_path()},
      {OmnigateControl.Ledger, path: ledger_path()},
      {Bandit, plug: OmnigateControl.Router, ip: {127, 0, 0, 1}, port: port()}
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

  defp port do
    case System.get_env("OMNIGATE_CONTROL_PORT") do
      nil -> Application.get_env(:omnigate_control, :port, 4000)
      v -> String.to_integer(v)
    end
  end
end
