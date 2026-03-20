defmodule SyncDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :sync_demo,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: [:exclosured] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SyncDemo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:exclosured, path: "../.."}
    ]
  end
end
