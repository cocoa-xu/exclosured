defmodule Exclosured do
  @moduledoc """
  Exclosured compiles Rust code to WebAssembly and runs it in browser
  sandboxes with Phoenix LiveView bidirectional communication.

  ## Configuration

      config :exclosured,
        source_dir: "native/wasm",
        output_dir: "priv/static/wasm",
        optimize: :none,
        modules: [
          my_mod: [mode: :compute],
          renderer: [mode: :interactive, canvas: true]
        ]
  """

  @doc """
  Returns the filesystem path to the compiled .wasm file for a module.
  """
  def wasm_path(module_name) when is_atom(module_name) do
    config = Exclosured.Config.read()
    mod = Exclosured.Config.module_config(config, module_name)

    if mod && mod.wasm_bindgen do
      name = Atom.to_string(module_name)
      Path.join([config.output_dir, name, "#{name}_bg.wasm"])
    else
      Path.join(config.output_dir, "#{module_name}.wasm")
    end
  end

  @doc """
  Returns the browser-accessible URL path for a module's .wasm file.
  """
  def wasm_url(module_name) when is_atom(module_name) do
    config = Exclosured.Config.read()
    mod = Exclosured.Config.module_config(config, module_name)

    if mod && mod.wasm_bindgen do
      name = Atom.to_string(module_name)
      "/wasm/#{name}/#{name}_bg.wasm"
    else
      "/wasm/#{module_name}.wasm"
    end
  end

  @doc """
  Returns the URL for a module's wasm-bindgen JS glue file.
  Only applicable for modules with wasm_bindgen enabled.
  """
  def wasm_js_url(module_name) when is_atom(module_name) do
    name = Atom.to_string(module_name)
    "/wasm/#{name}/#{name}.js"
  end

  @doc """
  Returns the URL for an asset file associated with a module.
  """
  def asset_url(module_name, filename) when is_atom(module_name) do
    "/wasm/assets/#{module_name}/#{filename}"
  end

  @doc """
  Returns a list of all configured module names.
  """
  def modules do
    config = Exclosured.Config.read()
    Enum.map(config.modules, & &1.name)
  end
end
