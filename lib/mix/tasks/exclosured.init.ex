defmodule Mix.Tasks.Exclosured.Init do
  @moduledoc """
  Scaffolds the Exclosured project structure.

  Creates the `native/wasm/` directory with a Cargo workspace and an
  example Rust crate that compiles to WebAssembly.

      $ mix exclosured.init
      $ mix exclosured.init --module my_module
      $ mix exclosured.init --module image_filter --template worker
      $ mix exclosured.init --module renderer --template canvas

  ## Options

    * `--module` - Name of the module to create (default: "example")
    * `--template` - Template to use: default, worker, canvas, liveview-hook,
      or typed-events (default: "default")
  """

  use Mix.Task

  @shortdoc "Initialize Exclosured project structure"

  @switches [module: :string, template: :string]
  @template_names ~w(default worker canvas liveview-hook typed-events)
  @template_aliases %{
    "basic" => "default",
    "hook" => "liveview-hook"
  }

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    module_name = Keyword.get(opts, :module, "example")
    template = opts |> Keyword.get(:template, "default") |> normalize_template!()

    unless Regex.match?(~r/^[a-z_][a-z0-9_]*$/, module_name) do
      Mix.raise("Invalid module name: #{inspect(module_name)}. Must match [a-z_][a-z0-9_]*.")
    end

    source_dir = Application.get_env(:exclosured, :source_dir, "native/wasm")

    create_workspace(source_dir, module_name)
    create_module(source_dir, module_name, template)
    print_next_steps(module_name, template)
  end

  defp normalize_template!(template) when is_binary(template) do
    template = Map.get(@template_aliases, template, template)

    if template in @template_names do
      template
    else
      valid = Enum.join(@template_names ++ Map.keys(@template_aliases), ", ")
      Mix.raise("Invalid template: #{inspect(template)}. Valid templates: #{valid}.")
    end
  end

  defp create_workspace(source_dir, module_name) do
    cargo_toml = Path.join(source_dir, "Cargo.toml")

    if File.exists?(cargo_toml) do
      # Add to existing workspace
      content = File.read!(cargo_toml)

      unless String.contains?(content, "\"#{module_name}\"") do
        updated =
          Regex.replace(
            ~r/members\s*=\s*\[([^\]]*)\]/,
            content,
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

  defp create_module(source_dir, module_name, template) do
    mod_dir = Path.join([source_dir, module_name, "src"])
    File.mkdir_p!(mod_dir)

    # Cargo.toml
    cargo_toml_path = Path.join([source_dir, module_name, "Cargo.toml"])

    unless File.exists?(cargo_toml_path) do
      cargo_content = module_cargo_toml(module_name, template)
      File.write!(cargo_toml_path, cargo_content)
      Mix.shell().info("Created #{cargo_toml_path}")
    end

    # lib.rs
    lib_rs_path = Path.join(mod_dir, "lib.rs")

    unless File.exists?(lib_rs_path) do
      lib_content = template_lib_rs(template)
      File.write!(lib_rs_path, lib_content)
      Mix.shell().info("Created #{lib_rs_path}")
    end
  end

  defp module_cargo_toml(name, template) do
    wasm_bindgen_requirement = Exclosured.WasmBindgen.dependency_requirement()

    dependencies =
      [
        ~s(wasm-bindgen = "#{wasm_bindgen_requirement}"),
        ~s(exclosured_guest = "0.1.4")
        | template_dependencies(template)
      ]
      |> Enum.join("\n")

    """
    [package]
    name = "#{name}"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    #{dependencies}
    """
  end

  defp template_dependencies(template) when template in ["canvas", "liveview-hook"] do
    [
      ~s(web-sys = { version = "0.3", features = ["CanvasRenderingContext2d", "HtmlCanvasElement"] })
    ]
  end

  defp template_dependencies(_template), do: []

  defp template_lib_rs("default") do
    """
    use wasm_bindgen::prelude::*;
    use exclosured_guest as exclosured;

    #[wasm_bindgen]
    pub fn compute(input: i32) -> i32 {
        exclosured::emit("progress", r#"{"percent":100}"#);
        input * input
    }
    """
  end

  defp template_lib_rs("worker") do
    """
    use std::cell::Cell;
    use wasm_bindgen::prelude::*;
    use exclosured_guest as exclosured;

    thread_local! {
        static CANCELED: Cell<bool> = Cell::new(false);
    }

    #[wasm_bindgen]
    pub fn process_items(count: u32) -> u32 {
        CANCELED.with(|canceled| canceled.set(false));

        let mut processed = 0;
        let step = (count / 10).max(1);

        for index in 0..count {
            if canceled() {
                exclosured::emit("canceled", &format!(r#"{{"processed":{}}}"#, processed));
                return processed;
            }

            let _score = expensive_score(index);
            processed += 1;

            if processed == count || processed % step == 0 {
                let percent = if count == 0 { 100 } else { processed * 100 / count };
                exclosured::emit("progress", &format!(r#"{{"percent":{}}}"#, percent));
            }
        }

        exclosured::emit("done", &format!(r#"{{"processed":{}}}"#, processed));
        processed
    }

    #[wasm_bindgen]
    pub fn cancel_call(_ref: &str) {
        CANCELED.with(|canceled| canceled.set(true));
    }

    fn canceled() -> bool {
        CANCELED.with(|canceled| canceled.get())
    }

    fn expensive_score(seed: u32) -> u32 {
        let mut value = seed;

        for _ in 0..128 {
            value = value.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        }

        value
    }
    """
  end

  defp template_lib_rs("canvas") do
    """
    use std::cell::RefCell;
    use wasm_bindgen::prelude::*;
    use wasm_bindgen::JsCast;
    use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

    thread_local! {
        static CONTEXT: RefCell<Option<CanvasRenderingContext2d>> = RefCell::new(None);
        static SIZE: RefCell<(f64, f64)> = RefCell::new((800.0, 600.0));
    }

    #[wasm_bindgen]
    pub fn init(canvas: HtmlCanvasElement) -> Result<(), JsValue> {
        let context = canvas
            .get_context("2d")?
            .ok_or_else(|| JsValue::from_str("2D canvas context is unavailable"))?
            .dyn_into::<CanvasRenderingContext2d>()?;

        let width = canvas.width() as f64;
        let height = canvas.height() as f64;

        CONTEXT.with(|ctx| *ctx.borrow_mut() = Some(context));
        SIZE.with(|size| *size.borrow_mut() = (width, height));
        redraw("#1f8fff");

        Ok(())
    }

    #[wasm_bindgen]
    pub fn apply_state(data: &[u8]) {
        let color = std::str::from_utf8(data)
            .ok()
            .and_then(|json| extract_string(json, "color"))
            .unwrap_or_else(|| "#1f8fff".to_string());

        redraw(&color);
    }

    fn redraw(color: &str) {
        let (width, height) = SIZE.with(|size| *size.borrow());

        CONTEXT.with(|ctx| {
            if let Some(ctx) = ctx.borrow().as_ref() {
                ctx.set_fill_style_str("#101418");
                ctx.fill_rect(0.0, 0.0, width, height);

                ctx.set_fill_style_str(color);
                ctx.begin_path();
                let _ = ctx.arc(width / 2.0, height / 2.0, height.min(width) * 0.25, 0.0, std::f64::consts::TAU);
                ctx.fill();
            }
        });
    }

    fn extract_string(json: &str, key: &str) -> Option<String> {
        let pattern = format!(r#""{}":""#, key);
        let start = json.find(&pattern)? + pattern.len();
        let end = json[start..].find('"')?;
        Some(json[start..start + end].to_string())
    }
    """
  end

  defp template_lib_rs("liveview-hook") do
    """
    use std::cell::RefCell;
    use wasm_bindgen::prelude::*;
    use wasm_bindgen::JsCast;
    use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

    thread_local! {
        static CONTEXT: RefCell<Option<CanvasRenderingContext2d>> = RefCell::new(None);
    }

    #[wasm_bindgen]
    pub fn init(canvas: HtmlCanvasElement) -> Result<(), JsValue> {
        let context = canvas
            .get_context("2d")?
            .ok_or_else(|| JsValue::from_str("2D canvas context is unavailable"))?
            .dyn_into::<CanvasRenderingContext2d>()?;

        context.set_fill_style_str("#16202a");
        context.fill_rect(0.0, 0.0, canvas.width() as f64, canvas.height() as f64);
        CONTEXT.with(|ctx| *ctx.borrow_mut() = Some(context));

        exclosured_guest::emit("hook_mounted", r#"{"ready":true}"#);
        Ok(())
    }

    #[wasm_bindgen]
    pub fn ping(message: &str) -> String {
        exclosured_guest::emit("ping", r#"{"received":true}"#);
        format!("pong: {}", message)
    }

    #[wasm_bindgen]
    pub fn apply_state(data: &[u8]) {
        let bytes = data.len();
        exclosured_guest::emit("state_applied", &format!(r#"{{"bytes":{}}}"#, bytes));
    }

    #[wasm_bindgen]
    pub fn destroyed() {
        CONTEXT.with(|ctx| *ctx.borrow_mut() = None);
        exclosured_guest::emit("hook_destroyed", r#"{}"#);
    }

    """
  end

  defp template_lib_rs("typed-events") do
    """
    use wasm_bindgen::prelude::*;
    use exclosured_guest as exclosured;

    /// exclosured:event
    pub struct JobStarted {
        pub total: u32,
    }

    /// exclosured:event
    pub struct JobProgress {
        pub percent: u32,
        pub label: String,
    }

    /// exclosured:event
    pub struct JobFinished {
        pub total: u32,
        pub ok: bool,
    }

    #[wasm_bindgen]
    pub fn run_job(total: u32) -> u32 {
        exclosured::emit("job_started", &format!(r#"{{"total":{}}}"#, total));

        let step = (total / 4).max(1);

        for item in 0..total {
            if item == total - 1 || item % step == 0 {
                let percent = if total == 0 { 100 } else { (item + 1) * 100 / total };
                let label = format!("item {}", item + 1);
                exclosured::emit(
                    "job_progress",
                    &format!(r#"{{"percent":{},"label":"{}"}}"#, percent, label),
                );
            }
        }

        exclosured::emit("job_finished", &format!(r#"{{"total":{},"ok":true}}"#, total));
        total
    }
    """
  end

  defp print_next_steps(module_name, template) do
    Mix.shell().info("""

    Exclosured project initialized!

    Template: #{template}

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
            #{module_name}: #{inspect(template_config(template))}
          ]

    3. Compile:

        mix compile

    4. Add the hook to your app.js:

        import { ExclosuredHook } from "exclosured";
        let liveSocket = new LiveSocket("/live", Socket, {
          hooks: { Exclosured: ExclosuredHook }
        });

    5. Use in your LiveView template:

        #{template_markup(module_name, template)}
    """)
  end

  defp template_config("worker"), do: [worker: true]
  defp template_config("canvas"), do: [canvas: true]
  defp template_config("liveview-hook"), do: [canvas: true]
  defp template_config(_template), do: []

  defp template_markup(module_name, template) when template in ["canvas", "liveview-hook"] do
    ~s(<Exclosured.LiveView.sandbox module={:#{module_name}} canvas />)
  end

  defp template_markup(module_name, _template) do
    ~s(<div id="wasm-#{module_name}" phx-hook="Exclosured" data-wasm-module="#{module_name}"></div>)
  end
end
