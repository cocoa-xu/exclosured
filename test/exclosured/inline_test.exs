defmodule Exclosured.InlineTest do
  use ExUnit.Case

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

  describe "defwasm macro" do
    test "generates wasm_url/0" do
      assert TestFilters.wasm_url() == "/wasm/exclosured_inline_test_test_filters.wasm"
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
  end
end
