defmodule Mix.Tasks.Exclosured.Rpc.TypesTest do
  use ExUnit.Case

  alias Mix.Tasks.Exclosured.Rpc.Types

  setup do
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "exclosured-rpc-types-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Mix.shell(old_shell)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "writes TypeScript declarations for annotated RPC exports", %{tmp_dir: tmp_dir} do
    out = Path.join([tmp_dir, "types", "processor.d.ts"])

    Types.run([
      "--source",
      "test/fixtures/test_rpc.rs",
      "--out",
      out,
      "--module-name",
      "ProcessorModule"
    ])

    declarations = File.read!(out)

    assert declarations =~ "export interface ProcessorModule"
    assert declarations =~ "export function score(input: string, factor: number): number;"
    assert declarations =~ "export function fetch_score(input: string): Promise<number>;"
    assert shell_output() =~ "Generated #{out}"
  end

  test "requires source and output paths" do
    assert_raise Mix.Error, ~r/Missing required --source option/, fn ->
      Types.run(["--out", "tmp.d.ts"])
    end

    assert_raise Mix.Error, ~r/Missing required --out option/, fn ->
      Types.run(["--source", "test/fixtures/test_rpc.rs"])
    end
  end

  defp shell_output do
    receive do
      {:mix_shell, :info, [message]} -> message <> "\n" <> shell_output()
    after
      0 -> ""
    end
  end
end
