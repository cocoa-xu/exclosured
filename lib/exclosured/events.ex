defmodule Exclosured.Events do
  @moduledoc """
  Generate Elixir structs from annotated Rust structs.

  Annotate a Rust struct with `/// exclosured:event` and this module
  generates a corresponding Elixir struct with `defstruct`, type specs,
  and a `from_payload/1` helper for converting JSON maps.

  ## Usage

      defmodule MyApp.Events do
        use Exclosured.Events, source: "native/wasm/my_mod/src/lib.rs"
      end

  ## Rust Side

      /// exclosured:event
      pub struct ProgressEvent {
          pub percent: u32,
          pub stage: String,
      }

  ## Generated Elixir

      defmodule MyApp.Events.ProgressEvent do
        defstruct [:percent, :stage]

        @type t :: %__MODULE__{
          percent: integer(),
          stage: String.t()
        }

        def from_payload(%{"percent" => percent, "stage" => stage}) do
          %__MODULE__{percent: percent, stage: stage}
        end
      end

  ## Supported Rust Types

    * `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `usize`, `isize` -> `integer()`
    * `f32`, `f64` -> `float()`
    * `String`, `&str` -> `String.t()`
    * `bool` -> `boolean()`
    * `Vec<T>` -> `list(T)`
    * `Option<T>` -> `T | nil`
  """

  defmacro __using__(opts) do
    source = Keyword.fetch!(opts, :source)
    caller_module = __CALLER__.module

    # Read and parse at compile time
    content =
      case File.read(source) do
        {:ok, data} ->
          data

        {:error, reason} ->
          raise CompileError,
            description: "Cannot read #{source}: #{inspect(reason)}",
            file: __CALLER__.file,
            line: __CALLER__.line
      end

    # Make the compiler track this file for recompilation
    quote_source =
      quote do
        @external_resource unquote(source)
      end

    events = Exclosured.Events.Parser.parse(content)

    modules =
      for event <- events do
        module_name = Module.concat(caller_module, String.to_atom(event.name))
        fields = Enum.map(event.fields, fn f -> String.to_atom(f.name) end)

        type_specs =
          Enum.map(event.fields, fn f ->
            {String.to_atom(f.name), rust_type_to_typespec(f.type)}
          end)

        quote do
          defmodule unquote(module_name) do
            @moduledoc unquote("Auto-generated from Rust struct `#{event.name}`.")

            defstruct unquote(fields)

            @type t :: %__MODULE__{unquote_splicing(type_specs)}

            @doc "Convert a JSON payload map (string keys) to this struct."
            def from_payload(payload) when is_map(payload) do
              struct(
                __MODULE__,
                payload
                |> Enum.reduce(%{}, fn {k, v}, acc ->
                  try do
                    Map.put(acc, String.to_existing_atom(k), v)
                  rescue
                    ArgumentError -> acc
                  end
                end)
              )
            end

            @doc "List of field names as strings (matching JSON keys)."
            def fields, do: unquote(Enum.map(event.fields, & &1.name))
          end
        end
      end

    events_list_fn =
      quote do
        @doc "List all generated event struct modules."
        def __events__ do
          unquote(
            Enum.map(events, fn e ->
              Module.concat(caller_module, String.to_atom(e.name))
            end)
          )
        end
      end

    [quote_source | modules] ++ [events_list_fn]
  end

  defp rust_type_to_typespec("u8"), do: quote(do: integer())
  defp rust_type_to_typespec("u16"), do: quote(do: integer())
  defp rust_type_to_typespec("u32"), do: quote(do: integer())
  defp rust_type_to_typespec("u64"), do: quote(do: integer())
  defp rust_type_to_typespec("i8"), do: quote(do: integer())
  defp rust_type_to_typespec("i16"), do: quote(do: integer())
  defp rust_type_to_typespec("i32"), do: quote(do: integer())
  defp rust_type_to_typespec("i64"), do: quote(do: integer())
  defp rust_type_to_typespec("usize"), do: quote(do: integer())
  defp rust_type_to_typespec("isize"), do: quote(do: integer())
  defp rust_type_to_typespec("f32"), do: quote(do: float())
  defp rust_type_to_typespec("f64"), do: quote(do: float())
  defp rust_type_to_typespec("bool"), do: quote(do: boolean())
  defp rust_type_to_typespec("String"), do: quote(do: String.t())
  defp rust_type_to_typespec("&str"), do: quote(do: String.t())
  defp rust_type_to_typespec("Vec<" <> rest), do: quote(do: list(unquote(rust_type_to_typespec(String.trim_trailing(rest, ">")))))
  defp rust_type_to_typespec("Option<" <> rest), do: quote(do: unquote(rust_type_to_typespec(String.trim_trailing(rest, ">"))) | nil)
  defp rust_type_to_typespec(_), do: quote(do: any())
end
