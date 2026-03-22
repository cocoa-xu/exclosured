defmodule LiveSvelteWasm.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_svelte_wasm,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: [:exclosured] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {LiveSvelteWasm.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:live_svelte, "~> 0.14"},
      {:exclosured, path: "../.."}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": ["cmd --cd assets node build.js"]
    ]
  end
end
