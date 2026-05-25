defmodule Exclosured.DoctorTest do
  use ExUnit.Case

  alias Exclosured.Doctor

  setup do
    on_exit(fn ->
      Application.delete_env(:exclosured, :source_dir)
      Application.delete_env(:exclosured, :output_dir)
      Application.delete_env(:exclosured, :optimize)
      Application.delete_env(:exclosured, :modules)
    end)
  end

  test "reports a healthy configured project" do
    cwd = build_project()

    Application.put_env(:exclosured, :source_dir, "native/wasm")
    Application.put_env(:exclosured, :output_dir, "priv/static/wasm")
    Application.put_env(:exclosured, :modules, demo: [])

    checks = diagnose(cwd)

    assert status(checks, "config") == :ok
    assert status(checks, "cargo") == :ok
    assert status(checks, "wasm32 target") == :ok
    assert status(checks, "wasm-bindgen") == :ok
    assert status(checks, "module demo") == :ok
    assert status(checks, "Phoenix static") == :ok
    assert status(checks, "npm package") == :ok
    refute Doctor.failed?(checks)
  end

  test "reports missing module source and static setup issues" do
    cwd = build_project(endpoint_static: ~w(assets fonts))

    Application.put_env(:exclosured, :source_dir, "native/wasm")
    Application.put_env(:exclosured, :modules, missing: [])

    checks = diagnose(cwd)

    assert status(checks, "module missing") == :error
    assert status(checks, "Phoenix static") == :warning
    assert Doctor.failed?(checks)
  end

  test "reports invalid config without raising" do
    Application.put_env(:exclosured, :optimize, :invalid)

    checks = diagnose(build_project())

    assert status(checks, "config") == :error
    assert message(checks, "config") =~ "Invalid :optimize"
  end

  test "warns when wasm-opt is missing and optimization is enabled" do
    Application.put_env(:exclosured, :optimize, :size)

    checks =
      build_project()
      |> diagnose(find_executable: fake_find_executable(%{"wasm-opt" => nil}))

    assert status(checks, "wasm-opt") == :warning
    assert message(checks, "wasm-opt") =~ "optimization will be skipped"
  end

  test "formats checks for shell output" do
    assert Doctor.format_check(%{status: :warning, name: "wasm-opt", message: "not found"}) ==
             "[WARN] wasm-opt: not found"
  end

  defp diagnose(cwd, opts \\ []) do
    Doctor.diagnose(
      Keyword.merge(
        [
          cwd: cwd,
          find_executable: fake_find_executable(),
          cmd: &fake_cmd/3
        ],
        opts
      )
    )
  end

  defp build_project(opts \\ []) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "exclosured-doctor-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    if Keyword.get(opts, :module?, true) do
      File.mkdir_p!(Path.join([tmp_dir, "native", "wasm", "demo", "src"]))

      File.write!(
        Path.join([tmp_dir, "native", "wasm", "demo", "Cargo.toml"]),
        "[package]\nname = \"demo\"\n"
      )
    end

    File.mkdir_p!(Path.join([tmp_dir, "priv", "static", "wasm"]))
    File.mkdir_p!(Path.join([tmp_dir, "lib", "demo_web"]))

    static_only = Keyword.get(opts, :endpoint_static, ~w(assets wasm fonts images))

    File.write!(Path.join([tmp_dir, "lib", "demo_web", "endpoint.ex"]), """
    defmodule DemoWeb.Endpoint do
      plug Plug.Static,
        at: "/",
        from: :demo,
        only: ~w(#{Enum.join(static_only, " ")})
    end
    """)

    File.mkdir_p!(Path.join([tmp_dir, "assets"]))

    File.write!(
      Path.join([tmp_dir, "assets", "package.json"]),
      ~s({"dependencies":{"exclosured":"0.1.4"}})
    )

    tmp_dir
  end

  defp fake_find_executable(overrides \\ %{}) do
    defaults = %{
      "cargo" => "/bin/cargo",
      "rustup" => "/bin/rustup",
      "wasm-bindgen" => "/bin/wasm-bindgen",
      "wasm-opt" => "/bin/wasm-opt"
    }

    paths = Map.merge(defaults, overrides)

    fn name -> Map.get(paths, name) end
  end

  defp fake_cmd("/bin/cargo", ["--version"], _opts), do: {"cargo 1.90.0", 0}

  defp fake_cmd("/bin/rustup", ["target", "list", "--installed"], _opts) do
    {"wasm32-unknown-unknown\n", 0}
  end

  defp fake_cmd("/bin/wasm-bindgen", ["--version"], _opts), do: {"wasm-bindgen 0.2.114", 0}

  defp status(checks, name) do
    checks |> check!(name) |> Map.fetch!(:status)
  end

  defp message(checks, name) do
    checks |> check!(name) |> Map.fetch!(:message)
  end

  defp check!(checks, name) do
    Enum.find(checks, &(&1.name == name)) || flunk("missing check #{inspect(name)}")
  end
end
