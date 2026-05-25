defmodule Exclosured.ManifestTest do
  use ExUnit.Case

  alias Exclosured.Manifest

  setup do
    on_exit(fn ->
      Manifest.clean()
      Application.delete_env(:exclosured, :modules)
    end)
  end

  describe "read/write" do
    test "returns empty map when no manifest exists" do
      Manifest.clean()
      assert Manifest.read() == %{}
    end

    test "roundtrips manifest data" do
      data = %{my_mod: %{mtimes: %{"src/lib.rs" => 12345}}}
      Manifest.write(data)
      assert Manifest.read() == data
    end
  end

  describe "path/0" do
    test "returns path under _build" do
      path = Manifest.path()
      assert String.contains?(path, "_build")
      assert String.ends_with?(path, "exclosured.manifest")
    end
  end

  describe "stale_modules/1" do
    test "returns no modules when manifest and output are current" do
      {config, module_config} = build_test_project()

      Manifest.write(Manifest.update_module(%{}, module_config, config))

      assert Manifest.stale_modules(config) == []
    end

    test "marks a module stale when compile options change" do
      {config, module_config} = build_test_project()

      Manifest.write(Manifest.update_module(%{}, module_config, config))

      assert Manifest.stale_modules(%{config | optimize: :size}) == [module_config]
    end

    test "marks a module stale when Cargo.lock changes" do
      {config, module_config} = build_test_project()

      Manifest.write(Manifest.update_module(%{}, module_config, config))
      File.write!(Path.join([config.source_dir, "demo", "Cargo.lock"]), "")

      assert Manifest.stale_modules(config) == [module_config]
    end
  end

  defp build_test_project do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "exclosured-manifest-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    source_dir = Path.join([tmp_dir, "native", "wasm"])
    output_dir = Path.join([tmp_dir, "priv", "static", "wasm"])

    File.mkdir_p!(Path.join([source_dir, "demo", "src"]))
    File.mkdir_p!(Path.join([output_dir, "demo"]))
    File.write!(Path.join([source_dir, "demo", "Cargo.toml"]), "[package]\nname = \"demo\"\n")
    File.write!(Path.join([source_dir, "demo", "src", "lib.rs"]), "pub fn demo() {}\n")
    File.write!(Path.join([output_dir, "demo", "demo_bg.wasm"]), <<0, 97, 115, 109>>)

    module_config = %{
      name: :demo,
      lib: false,
      canvas: false,
      features: [],
      no_default_features: false,
      subscribe: [],
      env: [],
      cargo_args: []
    }

    config = %Exclosured.Config{
      source_dir: source_dir,
      output_dir: output_dir,
      optimize: :none,
      modules: [module_config]
    }

    {config, module_config}
  end
end
