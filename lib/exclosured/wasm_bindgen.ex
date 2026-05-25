defmodule Exclosured.WasmBindgen do
  @moduledoc false

  @default_requirement "0.2"

  def cli_version do
    with path when is_binary(path) <- System.find_executable("wasm-bindgen"),
         {output, 0} <- System.cmd(path, ["--version"], stderr_to_stdout: true),
         [_, version] <- Regex.run(~r/wasm-bindgen\s+(\d+\.\d+\.\d+)/, output) do
      {:ok, version}
    else
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  def dependency_requirement do
    case cli_version() do
      {:ok, version} -> "=#{version}"
      :error -> @default_requirement
    end
  end
end
