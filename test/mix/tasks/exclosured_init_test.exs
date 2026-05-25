defmodule Mix.Tasks.Exclosured.InitTest do
  use ExUnit.Case

  alias Mix.Tasks.Exclosured.Init

  setup do
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "exclosured-init-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.put_env(:exclosured, :source_dir, "native/wasm")

    on_exit(fn ->
      Mix.shell(old_shell)
      Application.delete_env(:exclosured, :source_dir)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "generates the default module scaffold", %{tmp_dir: tmp_dir} do
    run_in(tmp_dir, ["--module", "scorer"])

    assert read(tmp_dir, "native/wasm/Cargo.toml") =~ ~s(members = ["scorer"])

    assert read(tmp_dir, "native/wasm/scorer/Cargo.toml") =~ ~s(name = "scorer")

    lib_rs = read(tmp_dir, "native/wasm/scorer/src/lib.rs")
    assert lib_rs =~ "pub fn compute(input: i32) -> i32"
    assert lib_rs =~ ~s(exclosured::emit("progress")
  end

  test "generates a worker-friendly module scaffold", %{tmp_dir: tmp_dir} do
    run_in(tmp_dir, ["--module", "jobs", "--template", "worker"])

    lib_rs = read(tmp_dir, "native/wasm/jobs/src/lib.rs")
    assert lib_rs =~ "pub fn process_items(count: u32) -> u32"
    assert lib_rs =~ "pub fn cancel_call(_ref: &str)"

    refute read(tmp_dir, "native/wasm/jobs/Cargo.toml") =~ "web-sys"

    output = shell_output()
    assert output =~ "Template: worker"
    assert output =~ "jobs: [worker: true]"
  end

  test "adds modules to an existing workspace", %{tmp_dir: tmp_dir} do
    run_in(tmp_dir, ["--module", "first"])
    run_in(tmp_dir, ["--module", "second"])

    assert read(tmp_dir, "native/wasm/Cargo.toml") =~
             ~s(members = ["first", "second"])
  end

  test "generates a canvas module with browser dependencies", %{tmp_dir: tmp_dir} do
    run_in(tmp_dir, ["--module", "renderer", "--template", "canvas"])

    cargo_toml = read(tmp_dir, "native/wasm/renderer/Cargo.toml")
    assert cargo_toml =~ "web-sys"
    assert cargo_toml =~ "CanvasRenderingContext2d"

    lib_rs = read(tmp_dir, "native/wasm/renderer/src/lib.rs")
    assert lib_rs =~ "HtmlCanvasElement"
    assert lib_rs =~ "pub fn apply_state(data: &[u8])"

    assert shell_output() =~ "<Exclosured.LiveView.sandbox module={:renderer} canvas />"
  end

  test "generates a typed-events module scaffold", %{tmp_dir: tmp_dir} do
    run_in(tmp_dir, ["--module", "pipeline", "--template", "typed-events"])

    lib_rs = read(tmp_dir, "native/wasm/pipeline/src/lib.rs")
    assert lib_rs =~ "/// exclosured:event"
    assert lib_rs =~ "pub struct JobProgress"
    assert lib_rs =~ "pub fn run_job(total: u32) -> u32"
  end

  test "accepts hook as an alias for the liveview-hook template", %{tmp_dir: tmp_dir} do
    run_in(tmp_dir, ["--module", "dom_hook", "--template", "hook"])

    lib_rs = read(tmp_dir, "native/wasm/dom_hook/src/lib.rs")
    assert lib_rs =~ "hook_mounted"
    assert lib_rs =~ "pub fn destroyed()"
  end

  test "rejects unknown templates", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Invalid template/, fn ->
      run_in(tmp_dir, ["--module", "bad", "--template", "unknown"])
    end
  end

  defp run_in(tmp_dir, args) do
    File.cd!(tmp_dir, fn -> Init.run(args) end)
  end

  defp read(tmp_dir, path) do
    tmp_dir
    |> Path.join(path)
    |> File.read!()
  end

  defp shell_output do
    receive do
      {:mix_shell, :info, [message]} -> message <> "\n" <> shell_output()
    after
      0 -> ""
    end
  end
end
