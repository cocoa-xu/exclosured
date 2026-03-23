defmodule Exclosured.Inline do
  @moduledoc """
  Define small WASM functions inline in Elixir using `defwasm`.

  The Rust code is compiled to a standalone `.wasm` file at build time,
  then processed with wasm-bindgen for JS interop.
  No Cargo workspace, no `.rs` files needed. Just Rust inside Elixir.

  ## Example

      defmodule MyApp.Math do
        use Exclosured.Inline
        defwasm :add, args: [a: :i32, b: :i32], do: ~RUST"a + b"
      end

      defmodule MyApp.Filters do
        use Exclosured.Inline

        defwasm :grayscale, args: [pixels: :binary] do
          ~RUST\"\"\"
          for chunk in pixels.chunks_exact_mut(4) {
              let gray = (0.299 * chunk[0] as f32
                        + 0.587 * chunk[1] as f32
                        + 0.114 * chunk[2] as f32) as u8;
              chunk[0] = gray;
              chunk[1] = gray;
              chunk[2] = gray;
          }
          \"\"\"
        end
      end

  Use `~RUST` instead of `~S` to enable Rust syntax highlighting in editors.

  After `mix compile`:
    - `priv/static/wasm/my_app_filters/my_app_filters_bg.wasm` is generated
    - `MyApp.Filters.wasm_url()` returns `"/wasm/my_app_filters/my_app_filters_bg.wasm"`
    - `MyApp.Filters.wasm_js_url()` returns `"/wasm/my_app_filters/my_app_filters.js"`
    - Functions are callable from the browser via the JS loader

  ## Supported Arg Types

    * `:binary`: allocated in WASM memory, passed as (ptr, len), mutable
    * `:string`: allocated in WASM memory, passed as (ptr, len), read-only
    * `:i32`, `:u32`, `:f32`, `:f64`: passed directly as WASM values
  """

  defmacro __using__(_opts) do
    quote do
      import Exclosured.Inline, only: [defwasm: 2, defwasm: 3, sigil_RUST: 2]
      Module.register_attribute(__MODULE__, :__wasm_fns, accumulate: true)
      @before_compile Exclosured.Inline
    end
  end

  @doc ~S"""
  A sigil for inline Rust code. Works like `~S` (no interpolation),
  but signals to editor extensions that the content is Rust source.

  ## Example

      defwasm :add, args: [a: :i32, b: :i32] do
        ~RUST"a + b"
      end

      defwasm :hash, args: [data: :binary] do
        ~RUST\"\"\"
        let mut hash: u32 = 5381;
        for &byte in data.iter() {
            hash = hash.wrapping_mul(33).wrapping_add(byte as u32);
        }
        hash as i32
        \"\"\"
      end
  """
  defmacro sigil_RUST(term, _modifiers) do
    # Return the raw string, same as ~S
    term
  end

  @doc """
  Define an inline WASM function.

  The body must be a string containing Rust code that operates on the
  declared arguments. The generated Rust function receives proper FFI
  types automatically based on the arg type declarations.

  ## Options

    * `:args` - keyword list of `name: type` (default: `[]`)
    * `:return` - return type (default: `:i32`)
    * `:deps` - list of extra Cargo dependencies as `{name, version}` tuples
      (default: `[]`). These are added to the generated `Cargo.toml`.
      Example: `deps: [{"serde", "1"}, {"serde_json", "1"}]`
  """
  # One-liner: defwasm :name, args: [...], do: "code"
  defmacro defwasm(name, opts) when is_list(opts) do
    {body, opts} = Keyword.pop!(opts, :do)
    rust_code = extract_rust_code(body)
    do_defwasm(name, opts, rust_code)
  end

  defmacro defwasm(name, opts, do: {:__block__, _, [rust_code]})
           when is_binary(rust_code) do
    do_defwasm(name, opts, rust_code)
  end

  defmacro defwasm(name, opts, do: rust_code) when is_binary(rust_code) do
    do_defwasm(name, opts, rust_code)
  end

  # Support ~S sigil (no escape interpolation, preserves \" for Rust)
  defmacro defwasm(name, opts, do: {:sigil_S, _, [{:<<>>, _, [rust_code]}, _]})
           when is_binary(rust_code) do
    do_defwasm(name, opts, rust_code)
  end

  # Support ~RUST sigil (editor-friendly, enables syntax highlighting)
  defmacro defwasm(name, opts, do: {:sigil_RUST, _, [{:<<>>, _, [rust_code]}, _]})
           when is_binary(rust_code) do
    do_defwasm(name, opts, rust_code)
  end

  defp extract_rust_code(code) when is_binary(code), do: code
  defp extract_rust_code({:__block__, _, [code]}) when is_binary(code), do: code
  defp extract_rust_code({:sigil_S, _, [{:<<>>, _, [code]}, _]}) when is_binary(code), do: code
  defp extract_rust_code({:sigil_RUST, _, [{:<<>>, _, [code]}, _]}) when is_binary(code), do: code

  defp do_defwasm(name, opts, rust_code) do
    quote do
      @__wasm_fns {
        unquote(name),
        unquote(Keyword.get(opts, :args, [])),
        unquote(Keyword.get(opts, :return, :i32)),
        unquote(rust_code),
        unquote(Keyword.get(opts, :deps, []))
      }
    end
  end

  defmacro __before_compile__(env) do
    functions = Module.get_attribute(env.module, :__wasm_fns) |> Enum.reverse()
    module_name = wasm_module_name(env.module)
    output_dir = Application.get_env(:exclosured, :output_dir, "priv/static/wasm")

    # Compile at build time, get the absolute output directory
    abs_output_dir = compile_inline_module(module_name, functions, output_dir)

    # Generate Elixir bindings (only when LiveView is available)
    fn_defs =
      if Code.ensure_loaded?(Exclosured.LiveView) do
        for {name, args, _ret, _rust, _deps} <- functions do
          arg_names = Keyword.keys(args)
          arg_vars = Enum.map(arg_names, &Macro.var(&1, nil))

          quote do
            @doc "Call `#{unquote(name)}` on the client's WASM instance via LiveView."
            def unquote(name)(socket, unquote_splicing(arg_vars)) do
              Exclosured.LiveView.call(
                socket,
                unquote(String.to_atom(module_name)),
                unquote(to_string(name)),
                [unquote_splicing(arg_vars)]
              )
            end
          end
        end
      else
        []
      end

    meta =
      quote do
        @doc "URL path to the compiled .wasm file."
        def wasm_url, do: unquote("/wasm/#{module_name}/#{module_name}_bg.wasm")

        @doc "URL path to the wasm-bindgen JS glue file."
        def wasm_js_url, do: unquote("/wasm/#{module_name}/#{module_name}.js")

        @doc "Filesystem path to the compiled .wasm file."
        def wasm_path, do: unquote(Path.join(abs_output_dir, "#{module_name}_bg.wasm"))

        @doc "Module name used for the .wasm file."
        def wasm_module_name, do: unquote(module_name)

        @doc "List of exported WASM function names."
        def wasm_exports do
          unquote(Enum.map(functions, fn {name, _, _, _, _} -> name end))
        end
      end

    [meta | fn_defs]
  end

  # --- Compile-time helpers ---

  defp wasm_module_name(module) do
    module
    |> Module.split()
    |> Enum.map_join("_", &Macro.underscore/1)
  end

  defp compile_inline_module(module_name, functions, output_dir) do
    crate_dir = Path.join([Mix.Project.build_path(), "exclosured_inline", module_name])
    src_dir = Path.join(crate_dir, "src")
    File.mkdir_p!(src_dir)

    # Collect extra deps from all functions
    extra_deps =
      functions
      |> Enum.flat_map(fn {_, _, _, _, deps} -> deps end)
      |> Enum.uniq_by(fn
        {name, _} -> name
        {name, _, _} -> name
      end)

    extra_deps_toml =
      Enum.map_join(extra_deps, "\n", fn
        {name, version, opts} when is_list(opts) ->
          features = Keyword.get(opts, :features, [])

          if features == [] do
            "#{name} = \"#{version}\""
          else
            feat = Enum.map_join(features, ", ", &"\"#{&1}\"")
            "#{name} = { version = \"#{version}\", features = [#{feat}] }"
          end

        {name, version} ->
          "#{name} = \"#{version}\""
      end)

    # Write Cargo.toml
    File.write!(Path.join(crate_dir, "Cargo.toml"), """
    [package]
    name = "#{module_name}"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wasm-bindgen = "0.2"
    #{extra_deps_toml}

    [profile.release]
    opt-level = "z"
    lto = true
    """)

    # Write lib.rs with all functions
    rust_source = generate_lib_rs(functions)
    lib_rs_path = Path.join(src_dir, "lib.rs")

    # Recompile if source changed OR output files are missing
    out_dir = Path.expand(Path.join(output_dir, module_name))
    bg_wasm = Path.join(out_dir, "#{module_name}_bg.wasm")

    needs_compile =
      case File.read(lib_rs_path) do
        {:ok, existing} -> existing != rust_source or not File.exists?(bg_wasm)
        _ -> true
      end

    if needs_compile do
      File.write!(lib_rs_path, rust_source)

      target_dir = Path.join(crate_dir, "target")

      Mix.shell().info("Compiling inline WASM module: #{module_name}")

      case System.cmd(
             "cargo",
             [
               "build",
               "--target",
               "wasm32-unknown-unknown",
               "--release",
               "--manifest-path",
               Path.join(crate_dir, "Cargo.toml")
             ],
             stderr_to_stdout: true,
             into: IO.stream(:stdio, :line),
             env: [{"CARGO_TARGET_DIR", target_dir}]
           ) do
        {_, 0} ->
          wasm_src =
            Path.join([target_dir, "wasm32-unknown-unknown", "release", "#{module_name}.wasm"])

          out_dir = Path.expand(Path.join(output_dir, module_name))
          File.mkdir_p!(out_dir)

          # Run wasm-bindgen on the output
          case System.cmd(
                 "wasm-bindgen",
                 [
                   "--target",
                   "web",
                   "--out-dir",
                   out_dir,
                   "--out-name",
                   module_name,
                   wasm_src
                 ],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              bg_wasm = Path.join(out_dir, "#{module_name}_bg.wasm")
              size = File.stat!(bg_wasm).size
              Mix.shell().info("  #{bg_wasm} (#{div(size, 1024)} KB)")

            {output, code} ->
              Mix.raise(
                "wasm-bindgen failed for inline module #{module_name} (exit code: #{code}): #{output}"
              )
          end

        {_, code} ->
          Mix.raise("Failed to compile inline WASM module #{module_name} (exit code: #{code})")
      end
    end

    # Return the absolute output directory (used by wasm_path/0)
    Path.expand(Path.join(output_dir, module_name))
  end

  defp generate_lib_rs(functions) do
    fn_code =
      functions
      |> Enum.map(fn {name, args, _ret, rust_code, _deps} ->
        {params, setup} = build_ffi(args)

        """
        #[no_mangle]
        pub extern "C" fn #{name}(#{params}) -> i32 {
        #{setup}
        #{indent(rust_code, 4)}
        }
        """
      end)
      |> Enum.join("\n")

    """
    // Auto-generated by Exclosured.Inline. Do not edit.

    use wasm_bindgen::prelude::*;

    #[wasm_bindgen]
    pub fn __exclosured_inline_marker() -> i32 { 0 }

    #[no_mangle]
    pub extern "C" fn alloc(size: usize) -> *mut u8 {
        let mut buf = Vec::with_capacity(size);
        let ptr = buf.as_mut_ptr();
        core::mem::forget(buf);
        ptr
    }

    #[no_mangle]
    pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
        unsafe { drop(Vec::from_raw_parts(ptr, 0, size)); }
    }

    #{fn_code}
    """
  end

  defp build_ffi(args) do
    params =
      args
      |> Enum.flat_map(fn
        {name, :binary} -> [{"#{name}_ptr", "*mut u8"}, {"#{name}_len", "usize"}]
        {name, :string} -> [{"#{name}_ptr", "*const u8"}, {"#{name}_len", "usize"}]
        {name, type} -> [{"#{name}", to_rust_type(type)}]
      end)
      |> Enum.map(fn {n, t} -> "#{n}: #{t}" end)
      |> Enum.join(", ")

    setup =
      args
      |> Enum.map(fn
        {name, :binary} ->
          "    let #{name} = unsafe { core::slice::from_raw_parts_mut(#{name}_ptr, #{name}_len) };"

        {name, :string} ->
          "    let #{name} = unsafe { core::str::from_utf8_unchecked(core::slice::from_raw_parts(#{name}_ptr, #{name}_len)) };"

        _ ->
          ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {params, setup}
  end

  defp to_rust_type(:i32), do: "i32"
  defp to_rust_type(:u32), do: "u32"
  defp to_rust_type(:f32), do: "f32"
  defp to_rust_type(:f64), do: "f64"

  defp indent(code, spaces) do
    pad = String.duplicate(" ", spaces)

    code
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &"#{pad}#{&1}")
  end
end
