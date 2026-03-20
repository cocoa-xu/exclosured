defmodule Exclosured.ConfigTest do
  use ExUnit.Case

  setup do
    on_exit(fn ->
      Application.delete_env(:exclosured, :source_dir)
      Application.delete_env(:exclosured, :output_dir)
      Application.delete_env(:exclosured, :optimize)
      Application.delete_env(:exclosured, :modules)
    end)
  end

  describe "read/0" do
    test "returns defaults when no config" do
      config = Exclosured.Config.read()
      assert config.source_dir == "native/wasm"
      assert config.output_dir == "priv/static/wasm"
      assert config.optimize == :none
      assert config.modules == []
    end

    test "reads custom config" do
      Application.put_env(:exclosured, :source_dir, "custom/wasm")
      Application.put_env(:exclosured, :output_dir, "output/wasm")
      Application.put_env(:exclosured, :optimize, :speed)

      config = Exclosured.Config.read()
      assert config.source_dir == "custom/wasm"
      assert config.output_dir == "output/wasm"
      assert config.optimize == :speed
    end

    test "parses modules with defaults" do
      Application.put_env(:exclosured, :modules,
        my_mod: [],
        heavy: [features: ["simd"]]
      )

      config = Exclosured.Config.read()
      assert length(config.modules) == 2

      my_mod = Exclosured.Config.module_config(config, :my_mod)
      assert my_mod.name == :my_mod
      assert my_mod.canvas == false
      assert my_mod.features == []

      heavy = Exclosured.Config.module_config(config, :heavy)
      assert heavy.name == :heavy
      assert heavy.features == ["simd"]
    end

    test "raises on invalid optimize value" do
      Application.put_env(:exclosured, :optimize, :invalid)

      assert_raise Mix.Error, ~r/Invalid :optimize/, fn ->
        Exclosured.Config.read()
      end
    end
  end

  describe "compilable_modules/1" do
    test "excludes lib modules" do
      Application.put_env(:exclosured, :modules,
        shared: [lib: true],
        engine: [],
        renderer: [canvas: true]
      )

      config = Exclosured.Config.read()
      compilable = Exclosured.Config.compilable_modules(config)
      names = Enum.map(compilable, & &1.name)
      assert :shared not in names
      assert :engine in names
      assert :renderer in names
    end
  end

  describe "module_config/2" do
    test "returns nil for unknown module" do
      config = Exclosured.Config.read()
      assert Exclosured.Config.module_config(config, :unknown) == nil
    end
  end
end
