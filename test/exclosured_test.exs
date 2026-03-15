defmodule ExclosuredTest do
  use ExUnit.Case

  describe "wasm_path/1" do
    test "returns path for compute module" do
      Application.put_env(:exclosured, :modules, my_mod: [])
      path = Exclosured.wasm_path(:my_mod)
      assert path == "priv/static/wasm/my_mod.wasm"
    after
      Application.delete_env(:exclosured, :modules)
    end

    test "returns path for wasm-bindgen module" do
      Application.put_env(:exclosured, :modules, my_mod: [wasm_bindgen: true])
      path = Exclosured.wasm_path(:my_mod)
      assert path == "priv/static/wasm/my_mod/my_mod_bg.wasm"
    after
      Application.delete_env(:exclosured, :modules)
    end
  end

  describe "wasm_url/1" do
    test "returns URL for compute module" do
      Application.put_env(:exclosured, :modules, my_mod: [])
      assert Exclosured.wasm_url(:my_mod) == "/wasm/my_mod.wasm"
    after
      Application.delete_env(:exclosured, :modules)
    end

    test "returns URL for interactive module" do
      Application.put_env(:exclosured, :modules, renderer: [mode: :interactive])
      assert Exclosured.wasm_url(:renderer) == "/wasm/renderer/renderer_bg.wasm"
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
  end

  describe "modules/0" do
    test "returns configured module names" do
      Application.put_env(:exclosured, :modules,
        mod_a: [],
        mod_b: [mode: :interactive]
      )

      assert Exclosured.modules() == [:mod_a, :mod_b]
    after
      Application.delete_env(:exclosured, :modules)
    end
  end
end
