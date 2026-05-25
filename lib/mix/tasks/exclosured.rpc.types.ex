defmodule Mix.Tasks.Exclosured.Rpc.Types do
  @moduledoc """
  Generates TypeScript declarations for annotated Exclosured RPC exports.

      $ mix exclosured.rpc.types --source native/wasm/processor/src/lib.rs --out assets/js/processor.d.ts

  ## Options

    * `--source` - Rust source file containing `/// exclosured:rpc` annotations
    * `--out` - TypeScript declaration file to write
    * `--module-name` - Generated module interface name (default:
      "ExclosuredWasmModule")
  """

  use Mix.Task

  @shortdoc "Generate TypeScript declarations for annotated WASM RPC exports"

  @switches [source: :string, out: :string, module_name: :string]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    source = required!(opts, :source)
    out = required!(opts, :out)
    module_name = Keyword.get(opts, :module_name, "ExclosuredWasmModule")

    content = File.read!(source)

    declarations =
      Exclosured.RPC.TypeScript.generate_from_source(content,
        source: source,
        module_name: module_name
      )

    out
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(out, declarations)
    Mix.shell().info("Generated #{out}")
  end

  defp required!(opts, key) do
    Keyword.get(opts, key) ||
      Mix.raise("Missing required --#{String.replace(to_string(key), "_", "-")} option.")
  end
end
