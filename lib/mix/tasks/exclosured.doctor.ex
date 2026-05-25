defmodule Mix.Tasks.Exclosured.Doctor do
  @moduledoc """
  Checks the local Exclosured toolchain and project setup.

      $ mix exclosured.doctor

  The task is diagnostic-only. It reports missing tools and likely project
  setup issues, but it does not rewrite files.
  """

  use Mix.Task

  @shortdoc "Check Exclosured setup"

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")

    checks = Exclosured.Doctor.diagnose()

    Mix.shell().info("Exclosured doctor\n")
    Enum.each(checks, &Mix.shell().info(Exclosured.Doctor.format_check(&1)))

    if Exclosured.Doctor.failed?(checks) do
      Mix.raise("Exclosured doctor found #{Exclosured.Doctor.error_count(checks)} error(s)")
    end
  end
end
