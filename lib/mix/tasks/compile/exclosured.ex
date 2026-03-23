defmodule Mix.Tasks.Compile.Exclosured do
  @moduledoc """
  Mix compiler that builds Rust crates into WebAssembly.

  Add `:exclosured` to your project's compilers list:

      def project do
        [
          compilers: [:exclosured] ++ Mix.compilers(),
          ...
        ]
      end

  ## Configuration

      config :exclosured,
        source_dir: "native/wasm",        # where Cargo.toml crates live
        output_dir: "priv/static/wasm",   # where .wasm + .js output goes
        optimize: :none,                  # :none | :size | :speed (wasm-opt)
        modules: [
          my_mod: [],
          heavy_compute: [features: ["simd"]],
          sqlite: [
            no_default_features: true,
            features: ["bundled"],
            env: [CC_wasm32_unknown_unknown: "/usr/bin/clang"],
            cargo_args: ["--locked"]
          ]
        ]

  ## Module Options

  Each module accepts the following options:

  - `features` - List of cargo features to enable (passed as `--features a,b,c`)
  - `no_default_features` - If `true`, passes `--no-default-features` to cargo
  - `env` - Keyword list of environment variables for the cargo build
    (e.g., `[CC_wasm32_unknown_unknown: "/usr/bin/clang"]`)
  - `cargo_args` - List of extra arguments forwarded directly to `cargo build`
    (e.g., `["--locked", "--offline"]`)
  - `lib` - If `true`, marks this as a library crate (not compiled standalone)
  - `canvas` - If `true`, enables canvas integration
  - `subscribe` - List of event subscriptions
  """

  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    config = Exclosured.Config.read()
    stale = Exclosured.Manifest.stale_modules(config)

    if stale == [] do
      Mix.shell().info("All WASM modules are up to date")
      {:noop, []}
    else
      manifest = Exclosured.Manifest.read()

      {diagnostics, manifest} =
        Enum.reduce(stale, {[], manifest}, fn mod, {diags, manifest} ->
          case Exclosured.Compiler.compile_module(mod, config) do
            :ok ->
              manifest = Exclosured.Manifest.update_module(manifest, mod, config)
              {diags, manifest}

            {:error, message} ->
              diagnostic = %Mix.Task.Compiler.Diagnostic{
                compiler_name: "exclosured",
                file: Path.join([config.source_dir, Atom.to_string(mod.name), "src", "lib.rs"]),
                message: message,
                position: 0,
                severity: :error
              }

              {[diagnostic | diags], manifest}
          end
        end)

      Exclosured.Manifest.write(manifest)

      case diagnostics do
        [] -> {:ok, []}
        diags -> {:error, diags}
      end
    end
  end

  @impl true
  def manifests do
    [Exclosured.Manifest.path()]
  end

  @impl true
  def clean do
    config = Exclosured.Config.read()

    config
    |> Exclosured.Config.compilable_modules()
    |> Enum.each(fn mod ->
      name = Atom.to_string(mod.name)
      File.rm_rf!(Path.join(config.output_dir, name))
    end)

    Exclosured.Manifest.clean()
    :ok
  end
end
