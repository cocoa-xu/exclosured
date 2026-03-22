defmodule KinoExclosured.MixProject do
  use Mix.Project

  def project do
    [
      app: :kino_exclosured,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: [:exclosured] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    [setup: ["deps.get"]]
  end

  defp deps do
    [
      {:kino, "~> 0.14"},
      {:jason, "~> 1.0"},
      {:exclosured, path: "../.."}
    ]
  end
end
