defmodule Exclosured.Compiler do
  @moduledoc """
  Handles invocation of cargo, wasm-bindgen, and wasm-opt to compile
  Rust crates into WebAssembly artifacts.
  """

  require Logger

  @doc """
  Compiles a single WASM module. Returns :ok or {:error, reason}.
  """
  def compile_module(module_config, config) do
    with :ok <- check_prerequisites(),
         :ok <- cargo_build(module_config, config),
         :ok <- run_wasm_bindgen(module_config, config),
         :ok <- maybe_wasm_opt(module_config, config) do
      :ok
    end
  end

  @doc """
  Checks that required tools (cargo, wasm32 target, wasm-bindgen) are available.
  """
  def check_prerequisites do
    with :ok <- check_cargo(),
         :ok <- check_wasm32_target(),
         :ok <- check_wasm_bindgen() do
      :ok
    end
  end

  defp check_cargo do
    case System.find_executable("cargo") do
      nil ->
        Mix.raise("""
        `cargo` not found in PATH.

        Install Rust and Cargo:

            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

        Then restart your shell and try again.
        """)

      _path ->
        :ok
    end
  end

  defp check_wasm32_target do
    case System.cmd("rustup", ["target", "list", "--installed"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "wasm32-unknown-unknown") do
          :ok
        else
          Mix.raise("""
          The wasm32-unknown-unknown target is not installed.

          Install it with:

              rustup target add wasm32-unknown-unknown

          Then try again.
          """)
        end

      {_, _} ->
        # rustup might not be available; try cargo build anyway
        :ok
    end
  end

  defp check_wasm_bindgen do
    case System.find_executable("wasm-bindgen") do
      nil ->
        Mix.raise("""
        `wasm-bindgen` not found in PATH.

        Install it with:

            cargo install wasm-bindgen-cli

        Then try again.
        """)

      _path ->
        :ok
    end
  end

  defp cargo_build(module_config, config) do
    name = Atom.to_string(module_config.name)
    source_dir = config.source_dir

    args = [
      "build",
      "--target",
      "wasm32-unknown-unknown",
      "--release",
      "--manifest-path",
      Path.join([source_dir, name, "Cargo.toml"])
    ]

    args =
      case module_config.features do
        [] -> args
        features -> args ++ ["--features", Enum.join(features, ",")]
      end

    Logger.info("Compiling WASM module: #{name}")

    case System.cmd("cargo", args,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line),
           env: [{"CARGO_TARGET_DIR", cargo_target_dir(config)}]
         ) do
      {_, 0} ->
        :ok

      {_, code} ->
        {:error, "cargo build failed for #{name} (exit code: #{code})"}
    end
  end

  defp run_wasm_bindgen(module_config, config) do
    name = Atom.to_string(module_config.name)
    wasm_file = cargo_wasm_path(name, config)
    out_dir = Path.join(config.output_dir, name)
    File.mkdir_p!(out_dir)

    args = [
      "--target",
      "web",
      "--out-dir",
      out_dir,
      "--out-name",
      name,
      wasm_file
    ]

    case System.cmd("wasm-bindgen", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "wasm-bindgen failed for #{name}: #{output}"}
    end
  end

  defp maybe_wasm_opt(_module_config, %{optimize: :none}), do: :ok

  defp maybe_wasm_opt(module_config, config) do
    case System.find_executable("wasm-opt") do
      nil ->
        Logger.warning("wasm-opt not found, skipping optimization for #{module_config.name}")
        :ok

      _path ->
        name = Atom.to_string(module_config.name)
        wasm_file = Path.join([config.output_dir, name, "#{name}_bg.wasm"])

        opt_flag =
          case config.optimize do
            :speed -> "-O3"
            :size -> "-Oz"
          end

        case System.cmd("wasm-opt", [opt_flag, wasm_file, "-o", wasm_file],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, _} -> {:error, "wasm-opt failed for #{name}: #{output}"}
        end
    end
  end

  defp cargo_target_dir(config) do
    Path.join(config.source_dir, "target")
  end

  defp cargo_wasm_path(name, config) do
    Path.join([
      cargo_target_dir(config),
      "wasm32-unknown-unknown",
      "release",
      "#{name}.wasm"
    ])
  end
end
