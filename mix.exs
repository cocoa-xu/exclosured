defmodule Exclosured.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :exclosured,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:jason, "~> 1.0"},
      {:file_system, "~> 1.0", only: :dev, optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Compile Rust to WebAssembly and run it in browser sandboxes with Phoenix LiveView integration."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/cocoa-xu/exclosured"},
      files: ~w(lib priv native/exclosured_guest mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Exclosured",
      extras: ["README.md"]
    ]
  end
end
