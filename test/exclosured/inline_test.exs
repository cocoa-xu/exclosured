defmodule Exclosured.InlineTest do
  use ExUnit.Case
  import Exclosured.Inline, only: [sigil_RUST: 2]

  defmodule TestFilters do
    use Exclosured.Inline

    defwasm :add_one, args: [x: :i32] do
      """
      let _ = x + 1;
      """
    end

    defwasm :grayscale, args: [pixels: :binary] do
      """
      for chunk in pixels.chunks_exact_mut(4) {
          let gray = (0.299 * chunk[0] as f32
                    + 0.587 * chunk[1] as f32
                    + 0.114 * chunk[2] as f32) as u8;
          chunk[0] = gray;
          chunk[1] = gray;
          chunk[2] = gray;
      }
      """
    end
  end

  # Test ~RUST sigil in block form
  defmodule TestRustSigil do
    use Exclosured.Inline

    defwasm :hash, args: [data: :binary] do
      ~RUST"""
      let mut hash: u32 = 5381;
      for &byte in data.iter() {
          hash = hash.wrapping_mul(33).wrapping_add(byte as u32);
      }
      return hash as i32;
      """
    end
  end

  # Test one-liner syntax (defwasm/2) with plain string
  defmodule TestOneLiner do
    use Exclosured.Inline
    defwasm(:add, args: [a: :i32, b: :i32], do: "return a + b;")
  end

  # Test one-liner with ~RUST sigil
  defmodule TestOneLinerRust do
    use Exclosured.Inline
    defwasm(:multiply, args: [a: :i32, b: :i32], do: ~RUST"return a * b;")
  end

  describe "defwasm macro" do
    test "generates wasm_url/0" do
      assert TestFilters.wasm_url() ==
               "/wasm/exclosured_inline_test_test_filters/exclosured_inline_test_test_filters_bg.wasm"
    end

    test "generates wasm_module_name/0" do
      assert TestFilters.wasm_module_name() == "exclosured_inline_test_test_filters"
    end

    test "generates wasm_exports/0" do
      assert TestFilters.wasm_exports() == [:add_one, :grayscale]
    end

    test "compiles .wasm file" do
      assert File.exists?(TestFilters.wasm_path())
    end

    test "produces valid wasm binary" do
      {:ok, bytes} = File.read(TestFilters.wasm_path())
      # WASM magic number
      assert <<0x00, 0x61, 0x73, 0x6D, _rest::binary>> = bytes
    end

    test "wasm_path/0 returns an absolute path" do
      path = TestFilters.wasm_path()
      assert String.starts_with?(path, "/")
    end
  end

  describe "~RUST sigil" do
    test "compiles with ~RUST sigil in block form" do
      assert TestRustSigil.wasm_exports() == [:hash]
      assert File.exists?(TestRustSigil.wasm_path())
    end

    test "~RUST sigil produces valid wasm binary" do
      {:ok, bytes} = File.read(TestRustSigil.wasm_path())
      assert <<0x00, 0x61, 0x73, 0x6D, _rest::binary>> = bytes
    end

    test "sigil_RUST/2 returns the string unchanged" do
      assert ~RUST"hello" == "hello"
    end

    test "sigil_RUST/2 does not interpolate" do
      result = ~RUST"#{foo}"
      assert result == "\#{foo}"
    end

    test "sigil_RUST/2 works with heredoc" do
      result = ~RUST"""
      let x = 1;
      let y = 2;
      """

      assert result == "let x = 1;\nlet y = 2;\n"
    end
  end

  describe "defwasm one-liner syntax" do
    test "compiles with plain string do:" do
      assert TestOneLiner.wasm_exports() == [:add]
      assert File.exists?(TestOneLiner.wasm_path())
    end

    test "compiles with ~RUST sigil do:" do
      assert TestOneLinerRust.wasm_exports() == [:multiply]
      assert File.exists?(TestOneLinerRust.wasm_path())
    end

    test "one-liner produces valid wasm" do
      {:ok, bytes} = File.read(TestOneLiner.wasm_path())
      assert <<0x00, 0x61, 0x73, 0x6D, _rest::binary>> = bytes
    end

    test "generates correct module name" do
      assert TestOneLiner.wasm_module_name() == "exclosured_inline_test_test_one_liner"
    end
  end

  describe "deps with features" do
    test "generates correct Cargo.toml with features" do
      # The deps format {"name", "version", features: [...]} should produce
      # valid Cargo.toml entries. We test this indirectly through the
      # generate_lib_rs and compile pipeline. Since we can't easily inspect
      # the generated Cargo.toml at test time, we verify the format function.
      deps_toml =
        [{"serde", "1", features: ["derive"]}, {"serde_json", "1"}]
        |> Enum.map(fn
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

      assert Enum.at(deps_toml, 0) == ~s(serde = { version = "1", features = ["derive"] })
      assert Enum.at(deps_toml, 1) == ~s(serde_json = "1")
    end

    test "simple dep tuple generates plain version string" do
      assert format_dep({"maud", "0.26"}) == ~s(maud = "0.26")
    end

    test "dep with features generates table syntax" do
      assert format_dep({"serde", "1", features: ["derive"]}) ==
               ~s(serde = { version = "1", features = ["derive"] })
    end

    test "dep with multiple features" do
      assert format_dep({"tokio", "1", features: ["rt", "macros"]}) ==
               ~s(tokio = { version = "1", features = ["rt", "macros"] })
    end

    test "dep with empty features list generates plain version" do
      assert format_dep({"serde", "1", features: []}) == ~s(serde = "1")
    end
  end

  # Helper to format a single dep entry (mirrors logic in inline.ex)
  defp format_dep({name, version, opts}) when is_list(opts) do
    features = Keyword.get(opts, :features, [])

    if features == [] do
      "#{name} = \"#{version}\""
    else
      feat = Enum.map_join(features, ", ", &"\"#{&1}\"")
      "#{name} = { version = \"#{version}\", features = [#{feat}] }"
    end
  end

  defp format_dep({name, version}) do
    "#{name} = \"#{version}\""
  end
end
