defmodule Mix.Tasks.Exclosured.Init do
  @moduledoc """
  Scaffolds the Exclosured project structure.

  Creates the `native/wasm/` directory with a Cargo workspace and an
  example Rust crate that compiles to WebAssembly.

      $ mix exclosured.init
      $ mix exclosured.init --module my_module
      $ mix exclosured.init --module my_module --mode interactive

  ## Options

    * `--module` - Name of the module to create (default: "example")
    * `--mode` - Execution mode: "compute" or "interactive" (default: "compute")
  """

  use Mix.Task

  @shortdoc "Initialize Exclosured project structure"

  @switches [module: :string, mode: :string]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    module_name = Keyword.get(opts, :module, "example")
    mode = Keyword.get(opts, :mode, "compute")

    if mode not in ["compute", "interactive"] do
      Mix.raise("Invalid mode: #{mode}. Must be 'compute' or 'interactive'.")
    end

    source_dir = Application.get_env(:exclosured, :source_dir, "native/wasm")

    create_workspace(source_dir, module_name)
    create_module(source_dir, module_name, mode)
    print_next_steps(module_name, mode)
  end

  defp create_workspace(source_dir, module_name) do
    cargo_toml = Path.join(source_dir, "Cargo.toml")

    if File.exists?(cargo_toml) do
      # Add to existing workspace
      content = File.read!(cargo_toml)

      unless String.contains?(content, "\"#{module_name}\"") do
        updated =
          String.replace(
            content,
            ~r/members\s*=\s*\[([^\]]*)\]/,
            fn _, members ->
              existing = String.trim(members)

              new_members =
                if existing == "" do
                  "\"#{module_name}\""
                else
                  "#{existing}, \"#{module_name}\""
                end

              "members = [#{new_members}]"
            end
          )

        File.write!(cargo_toml, updated)
        Mix.shell().info("Updated #{cargo_toml} with module #{module_name}")
      end
    else
      File.mkdir_p!(source_dir)

      content = """
      [workspace]
      members = ["#{module_name}"]
      resolver = "2"
      """

      File.write!(cargo_toml, content)
      Mix.shell().info("Created #{cargo_toml}")
    end
  end

  defp create_module(source_dir, module_name, mode) do
    mod_dir = Path.join([source_dir, module_name, "src"])
    File.mkdir_p!(mod_dir)

    # Cargo.toml
    cargo_toml_path = Path.join([source_dir, module_name, "Cargo.toml"])

    unless File.exists?(cargo_toml_path) do
      cargo_content = module_cargo_toml(module_name, mode)
      File.write!(cargo_toml_path, cargo_content)
      Mix.shell().info("Created #{cargo_toml_path}")
    end

    # lib.rs
    lib_rs_path = Path.join(mod_dir, "lib.rs")

    unless File.exists?(lib_rs_path) do
      lib_content =
        case mode do
          "compute" -> compute_lib_rs()
          "interactive" -> interactive_lib_rs()
        end

      File.write!(lib_rs_path, lib_content)
      Mix.shell().info("Created #{lib_rs_path}")
    end
  end

  defp module_cargo_toml(name, "compute") do
    """
    [package]
    name = "#{name}"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    exclosured_guest = { path = "../../native/exclosured_guest" }
    """
  end

  defp module_cargo_toml(name, "interactive") do
    """
    [package]
    name = "#{name}"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wasm-bindgen = "0.2"
    web-sys = { version = "0.3", features = ["Window", "Document", "HtmlCanvasElement", "CanvasRenderingContext2d"] }
    exclosured_guest = { path = "../../native/exclosured_guest" }
    """
  end

  defp compute_lib_rs do
    """
    use exclosured_guest as exclosured;

    /// Example compute function.
    /// Receives a number and returns its square.
    #[no_mangle]
    pub extern "C" fn compute(input: i32) -> i32 {
        exclosured::emit("progress", r#"{"percent": 100}"#);
        input * input
    }
    """
  end

  defp interactive_lib_rs do
    """
    use wasm_bindgen::prelude::*;
    use web_sys::HtmlCanvasElement;

    #[wasm_bindgen(start)]
    pub fn start() {
        // Entry point called by wasm-bindgen
    }

    #[wasm_bindgen]
    pub fn init(canvas: HtmlCanvasElement) {
        let ctx = canvas
            .get_context("2d")
            .unwrap()
            .unwrap()
            .dyn_into::<web_sys::CanvasRenderingContext2d>()
            .unwrap();

        ctx.set_fill_style_str("green");
        ctx.fill_rect(10.0, 10.0, 100.0, 100.0);
    }

    #[wasm_bindgen]
    pub fn apply_state(_data: &[u8]) {
        // Handle state updates from LiveView
    }
    """
  end

  defp print_next_steps(module_name, mode) do
    Mix.shell().info("""

    Exclosured project initialized!

    Next steps:

    1. Add exclosured to your compilers in mix.exs:

        def project do
          [
            compilers: [:exclosured] ++ Mix.compilers(),
            ...
          ]
        end

    2. Configure your module in config/config.exs:

        config :exclosured,
          modules: [
            #{module_name}: [mode: :#{mode}]
          ]

    3. Compile:

        mix compile

    4. Add the hook to your app.js:

        import { ExclosuredHook } from "exclosured";
        let liveSocket = new LiveSocket("/live", Socket, {
          hooks: { Exclosured: ExclosuredHook }
        });

    5. Use in your LiveView template:

        <div id="wasm-#{module_name}" phx-hook="Exclosured" data-wasm-module="#{module_name}"></div>
    """)
  end
end
