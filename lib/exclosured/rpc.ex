if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Exclosured.RPC do
    @moduledoc """
    Generate LiveView RPC helpers from annotated Rust exports.

    Annotate a Rust export with `/// exclosured:rpc`, then use this module
    to generate Elixir functions that call the WASM export through
    `Exclosured.LiveView`.

        defmodule MyApp.Wasm do
          use Exclosured.RPC,
            source: "native/wasm/processor/src/lib.rs",
            module: :processor
        end

    For a Rust export named `score`, this generates `score/3` and
    `score_async/3` helpers. The async variant delegates to
    `Exclosured.LiveView.call_async/5` and returns `{:ok, ref, socket}`.
    """

    @reserved_var_names ~w(
      after and catch do else end false fn for if import nil not or receive rescue true try when
    )

    defmacro __using__(opts) do
      source = Keyword.fetch!(opts, :source)
      wasm_module = opts |> Keyword.fetch!(:module) |> validate_module!()

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

      rpcs = Exclosured.RPC.Parser.parse(content)

      quote_source =
        quote do
          @external_resource unquote(source)
        end

      rpc_fns =
        rpcs
        |> Enum.flat_map(&rpc_functions(&1, wasm_module))

      metadata_fns =
        quote do
          @doc "The configured Exclosured module for these RPC helpers."
          def __rpc_module__, do: unquote(wasm_module)

          @doc "List parsed RPC exports from the Rust source file."
          def __rpc__, do: unquote(Macro.escape(rpcs))
        end

      [quote_source | rpc_fns] ++ [metadata_fns]
    end

    defp validate_module!(module) when is_atom(module), do: module

    defp validate_module!(module) do
      raise ArgumentError, ":module must be an atom, got: #{inspect(module)}"
    end

    defp rpc_functions(rpc, wasm_module) do
      function_name = String.to_atom(rpc.name)
      async_function_name = String.to_atom("#{rpc.name}_async")

      args =
        rpc.args |> Enum.with_index(1) |> Enum.map(fn {arg, index} -> rpc_var(arg, index) end)

      arg_types = Enum.map(rpc.args, &rust_type_to_typespec(&1.type))
      wasm_func = rpc.name

      [
        quote do
          @doc unquote(
                 "Call WASM export `#{wasm_func}/#{length(args)}` on `#{inspect(wasm_module)}`."
               )
          @spec unquote(function_name)(
                  Phoenix.LiveView.Socket.t(),
                  unquote_splicing(arg_types),
                  keyword()
                ) ::
                  Phoenix.LiveView.Socket.t()
          def unquote(function_name)(socket, unquote_splicing(args), opts \\ []) do
            Exclosured.LiveView.call(
              socket,
              unquote(wasm_module),
              unquote(wasm_func),
              [unquote_splicing(args)],
              opts
            )
          end
        end,
        quote do
          @doc unquote(
                 "Call WASM export `#{wasm_func}/#{length(args)}` on `#{inspect(wasm_module)}` and return a correlated ref."
               )
          @spec unquote(async_function_name)(
                  Phoenix.LiveView.Socket.t(),
                  unquote_splicing(arg_types),
                  keyword()
                ) ::
                  {:ok, String.t(), Phoenix.LiveView.Socket.t()}
          def unquote(async_function_name)(socket, unquote_splicing(args), opts \\ []) do
            Exclosured.LiveView.call_async(
              socket,
              unquote(wasm_module),
              unquote(wasm_func),
              [unquote_splicing(args)],
              opts
            )
          end
        end
      ]
    end

    defp rpc_var(%{name: name}, index) do
      name =
        if valid_var_name?(name) do
          name
        else
          "arg#{index}"
        end

      Macro.var(String.to_atom(name), nil)
    end

    defp valid_var_name?(name) do
      Regex.match?(~r/^[a-z_][A-Za-z0-9_]*$/, name) and name not in @reserved_var_names
    end

    defp rust_type_to_typespec(type) do
      type
      |> normalize_type()
      |> rust_type_to_typespec_ast()
    end

    defp normalize_type(type) do
      type
      |> String.trim()
      |> String.replace(~r/&'[A-Za-z_][A-Za-z0-9_]*\s+/, "&")
      |> String.replace(~r/\s+/, "")
    end

    defp rust_type_to_typespec_ast(type)
         when type in ~w(u8 u16 u32 u64 i8 i16 i32 i64 usize isize),
         do: quote(do: integer())

    defp rust_type_to_typespec_ast(type) when type in ~w(f32 f64), do: quote(do: float())
    defp rust_type_to_typespec_ast("bool"), do: quote(do: boolean())
    defp rust_type_to_typespec_ast(type) when type in ~w(String &str), do: quote(do: String.t())
    defp rust_type_to_typespec_ast(type) when type in ~w(&[u8] Vec<u8>), do: quote(do: binary())

    defp rust_type_to_typespec_ast("Vec<" <> rest) do
      quote(do: list(unquote(rust_type_to_typespec_ast(unwrap_generic(rest)))))
    end

    defp rust_type_to_typespec_ast("Option<" <> rest) do
      quote(do: unquote(rust_type_to_typespec_ast(unwrap_generic(rest))) | nil)
    end

    defp rust_type_to_typespec_ast(_type), do: quote(do: any())

    defp unwrap_generic(type) do
      if String.ends_with?(type, ">") do
        String.slice(type, 0, String.length(type) - 1)
      else
        type
      end
    end
  end
end
