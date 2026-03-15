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
end
