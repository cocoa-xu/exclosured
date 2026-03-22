defmodule ExclosuredTest do
  use ExUnit.Case

  describe "wasm_path/1" do
    test "returns wasm-bindgen path" do
      Application.put_env(:exclosured, :modules, my_mod: [])
      path = Exclosured.wasm_path(:my_mod)
      assert path == "priv/static/wasm/my_mod/my_mod_bg.wasm"
    after
      Application.delete_env(:exclosured, :modules)
    end
  end

  describe "wasm_url/1" do
    test "returns wasm-bindgen URL" do
      Application.put_env(:exclosured, :modules, my_mod: [])
      assert Exclosured.wasm_url(:my_mod) == "/wasm/my_mod/my_mod_bg.wasm"
    after
      Application.delete_env(:exclosured, :modules)
    end
  end

  describe "wasm_js_url/1" do
    test "returns JS glue URL" do
      assert Exclosured.wasm_js_url(:my_mod) == "/wasm/my_mod/my_mod.js"
    end
  end

  describe "asset_url/2" do
    test "returns asset URL" do
      assert Exclosured.asset_url(:ai_engine, "model.onnx") ==
               "/wasm/assets/ai_engine/model.onnx"
    end

    test "strips directory components from filename" do
      assert Exclosured.asset_url(:ai_engine, "../../../etc/passwd") ==
               "/wasm/assets/ai_engine/passwd"
    end

    test "handles nested path traversal" do
      assert Exclosured.asset_url(:mod, "foo/bar/../../secret.txt") ==
               "/wasm/assets/mod/secret.txt"
    end
  end

  describe "modules/0" do
    test "returns configured module names" do
      Application.put_env(:exclosured, :modules,
        mod_a: [],
        mod_b: [canvas: true]
      )

      assert Exclosured.modules() == [:mod_a, :mod_b]
    after
      Application.delete_env(:exclosured, :modules)
    end
  end
end
