defmodule OmnigateControl.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = env_int("OMNIGATE_CONTROL_PORT", 4000)

    children = [
      {OmnigateControl.ConfigStore, path: config_path()},
      {OmnigateControl.Ledger, path: ledger_path()},
      {Bandit, plug: OmnigateControl.Router, ip: {127, 0, 0, 1}, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OmnigateControl.Supervisor)
  end

  defp config_path do
    System.get_env("OMNIGATE_CONFIG") ||
      Path.expand("../config/omnigate.dev.json", File.cwd!())
  end

  defp ledger_path do
    System.get_env("OMNIGATE_LEDGER") || Path.expand("data/ledger.jsonl", File.cwd!())
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  end
end
