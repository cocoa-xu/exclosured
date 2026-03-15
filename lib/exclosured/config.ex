defmodule Exclosured.Config do
  @moduledoc """
  Parses and validates Exclosured configuration.
  """

  @default_source_dir "native/wasm"
  @default_output_dir "priv/static/wasm"
  @valid_modes [:compute, :interactive]
  @valid_optimize [:none, :size, :speed]

  defstruct [
    :source_dir,
    :output_dir,
    :optimize,
    :wasm_bindgen,
    :modules
  ]

  @doc """
  Reads configuration from application env and returns a validated config struct.
  """
  def read do
    config = Application.get_all_env(:exclosured)

    %__MODULE__{
      source_dir: Keyword.get(config, :source_dir, @default_source_dir),
      output_dir: Keyword.get(config, :output_dir, @default_output_dir),
      optimize: Keyword.get(config, :optimize, :none),
      wasm_bindgen: Keyword.get(config, :wasm_bindgen, false),
      modules: parse_modules(Keyword.get(config, :modules, []), config)
    }
    |> validate!()
  end

  @doc """
  Returns module config for a specific module name.
  """
  def module_config(%__MODULE__{modules: modules}, name) do
    Enum.find(modules, fn m -> m.name == name end)
  end

  @doc """
  Returns only compilable modules (non-lib modules).
  """
  def compilable_modules(%__MODULE__{modules: modules}) do
    Enum.reject(modules, fn m -> m.lib end)
  end

  defp parse_modules(modules, global_config) do
    global_wasm_bindgen = Keyword.get(global_config, :wasm_bindgen, false)

    Enum.map(modules, fn
      {name, opts} when is_atom(name) and is_list(opts) ->
        mode = Keyword.get(opts, :mode, :compute)
        lib = Keyword.get(opts, :lib, false)

        # Interactive mode forces wasm-bindgen on
        wasm_bindgen =
          if mode == :interactive do
            true
          else
            Keyword.get(opts, :wasm_bindgen, global_wasm_bindgen)
          end

        %{
          name: name,
          mode: mode,
          lib: lib,
          wasm_bindgen: wasm_bindgen,
          canvas: Keyword.get(opts, :canvas, false),
          features: Keyword.get(opts, :features, []),
          subscribe: Keyword.get(opts, :subscribe, [])
        }

      name when is_atom(name) ->
        %{
          name: name,
          mode: :compute,
          lib: false,
          wasm_bindgen: global_wasm_bindgen,
          canvas: false,
          features: [],
          subscribe: []
        }
    end)
  end

  defp validate!(%__MODULE__{} = config) do
    validate_optimize!(config.optimize)
    Enum.each(config.modules, &validate_module!/1)
    config
  end

  defp validate_optimize!(opt) when opt in @valid_optimize, do: :ok

  defp validate_optimize!(opt) do
    Mix.raise("""
    Invalid :optimize option #{inspect(opt)}.
    Valid options: #{inspect(@valid_optimize)}
    """)
  end

  defp validate_module!(%{mode: mode}) when mode not in @valid_modes do
    Mix.raise("""
    Invalid module :mode #{inspect(mode)}.
    Valid modes: #{inspect(@valid_modes)}
    """)
  end

  defp validate_module!(_), do: :ok
end
