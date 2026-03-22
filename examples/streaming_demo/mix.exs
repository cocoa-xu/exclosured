defmodule StreamingDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :streaming_demo,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: [:exclosured] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {StreamingDemo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp aliases do
    [setup: ["deps.get"]]
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
