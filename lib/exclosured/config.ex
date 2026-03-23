defmodule Exclosured.Config do
  @moduledoc """
  Parses and validates Exclosured configuration.
  """

  @default_source_dir "native/wasm"
  @default_output_dir "priv/static/wasm"
  @valid_optimize [:none, :size, :speed]

  defstruct [
    :source_dir,
    :output_dir,
    :optimize,
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
      modules: parse_modules(Keyword.get(config, :modules, []))
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

  defp parse_modules(modules) do
    Enum.map(modules, fn
      {name, opts} when is_atom(name) and is_list(opts) ->
        %{
          name: name,
          lib: Keyword.get(opts, :lib, false),
          canvas: Keyword.get(opts, :canvas, false),
          features: Keyword.get(opts, :features, []),
          no_default_features: Keyword.get(opts, :no_default_features, false),
          subscribe: Keyword.get(opts, :subscribe, []),
          env: Keyword.get(opts, :env, []),
          cargo_args: Keyword.get(opts, :cargo_args, [])
        }

      name when is_atom(name) ->
        %{
          name: name,
          lib: false,
          canvas: false,
          features: [],
          no_default_features: false,
          subscribe: [],
          env: [],
          cargo_args: []
        }
    end)
  end

  defp validate!(%__MODULE__{} = config) do
    validate_optimize!(config.optimize)
    config
  end

  defp validate_optimize!(opt) when opt in @valid_optimize, do: :ok

  defp validate_optimize!(opt) do
    Mix.raise("""
    Invalid :optimize option #{inspect(opt)}.
    Valid options: #{inspect(@valid_optimize)}
    """)
  end
end
