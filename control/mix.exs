defmodule OmnigateControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :omnigate_control,
      version: "0.1.0-rc.1",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # No :inets: outbound HTTP is `OmnigateControl.Http`, on :gen_tcp and :ssl.
      extra_applications: [:logger, :crypto, :ssl, :public_key],
      mod: {OmnigateControl.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end
end
