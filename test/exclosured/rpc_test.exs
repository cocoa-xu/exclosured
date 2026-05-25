defmodule Exclosured.RPCTest do
  use ExUnit.Case

  alias Exclosured.RPC.Parser

  @test_rs_path "test/fixtures/test_rpc.rs"

  describe "Parser.parse/1" do
    test "parses annotated RPC functions" do
      rpcs = @test_rs_path |> File.read!() |> Parser.parse()

      assert Enum.map(rpcs, & &1.name) == [
               "score",
               "tokenize",
               "digest",
               "version",
               "fetch_score"
             ]

      refute Enum.any?(rpcs, &(&1.name == "internal"))
    end

    test "extracts function arguments and return types" do
      [score, tokenize, digest, version, fetch_score] =
        @test_rs_path |> File.read!() |> Parser.parse()

      assert score.args == [
               %{name: "input", type: "String"},
               %{name: "factor", type: "f64"}
             ]

      assert score.return == "f64"
      refute score.async

      assert tokenize.args == [
               %{name: "text", type: "&str"},
               %{name: "limit", type: "Option<u32>"}
             ]

      assert tokenize.return == "Vec<String>"
      assert digest.args == [%{name: "data", type: "&[u8]"}]
      assert version.args == []
      assert version.return == "String"
      assert fetch_score.args == [%{name: "input", type: "String"}]
      assert fetch_score.return == "u32"
      assert fetch_score.async
    end

    test "handles empty source" do
      assert Parser.parse("") == []
    end

    test "handles source without RPC annotations" do
      source = """
      #[wasm_bindgen]
      pub fn ignored(input: String) -> String {
          input
      }
      """

      assert Parser.parse(source) == []
    end
  end

  describe "use Exclosured.RPC" do
    defmodule TestRPC do
      use Exclosured.RPC, source: "test/fixtures/test_rpc.rs", module: :processor
    end

    test "generates metadata helpers" do
      assert TestRPC.__rpc_module__() == :processor

      assert Enum.map(TestRPC.__rpc__(), & &1.name) == [
               "score",
               "tokenize",
               "digest",
               "version",
               "fetch_score"
             ]
    end

    test "generated sync helpers delegate to Exclosured.LiveView.call/5" do
      socket = build_socket()

      returned_socket =
        TestRPC.score(socket, "hello", 2.0, fallback: fn ["hello", 2.0] -> 10.0 end)

      assert returned_socket == socket
      assert_receive {:wasm_result, :processor, "score", 10.0}
    end

    test "generated async helpers delegate to Exclosured.LiveView.call_async/5" do
      socket = build_socket()

      {:ok, ref, returned_socket} =
        TestRPC.tokenize_async(socket, "hello world", 1,
          fallback: fn ["hello world", 1] -> ["hello"] end
        )

      assert returned_socket == socket
      assert is_binary(ref)
      assert_receive {:wasm_result, ^ref, :processor, "tokenize", ["hello"]}
    end

    test "generated helpers push calls when WASM is ready" do
      socket = build_push_socket() |> mark_ready(:processor)
      socket = TestRPC.digest(socket, <<1, 2, 3>>)

      assert %{
               module: :processor,
               func: "digest",
               args: [<<1, 2, 3>>],
               ref: ref
             } = pushed_payload(socket, "wasm:call")

      assert is_binary(ref)
    end

    test "generated zero-argument helpers accept opts" do
      socket = build_socket()
      returned_socket = TestRPC.version(socket, fallback: fn [] -> "1.0.0" end)

      assert returned_socket == socket
      assert_receive {:wasm_result, :processor, "version", "1.0.0"}
    end
  end

  describe "TypeScript.generate/2" do
    test "generates declarations from parsed RPC metadata" do
      declarations =
        @test_rs_path
        |> File.read!()
        |> Exclosured.RPC.TypeScript.generate_from_source(
          source: @test_rs_path,
          module_name: "ProcessorModule"
        )

      assert declarations =~ "// Source: #{@test_rs_path}"
      assert declarations =~ "export interface ProcessorModule {"
      assert declarations =~ "score: (input: string, factor: number) => number;"
      assert declarations =~ "tokenize: (text: string, limit: number | null) => string[];"
      assert declarations =~ "digest: (data: Uint8Array) => number;"
      assert declarations =~ "version: () => string;"
      assert declarations =~ "fetch_score: (input: string) => Promise<number>;"
      assert declarations =~ "export function fetch_score(input: string): Promise<number>;"
    end

    test "falls back to safe TypeScript names and unknown custom types" do
      declarations =
        [
          %{
            name: "run",
            args: [
              %{name: "type", type: "Vec<Option<u32>>"},
              %{name: "result", type: "ScoreResult"}
            ],
            return: "ScoreResult",
            async: false
          }
        ]
        |> Exclosured.RPC.TypeScript.generate()

      assert declarations =~ "run: (arg1: Array<number | null>, result: unknown) => unknown;"
    end

    test "validates generated interface names" do
      assert_raise ArgumentError, ~r/invalid TypeScript interface name/, fn ->
        Exclosured.RPC.TypeScript.generate([], module_name: "bad-name")
      end
    end
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }
  end

  defp build_push_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}}
    }
  end

  defp mark_ready(socket, module) do
    put_in(socket, [Access.key(:private), :exclosured_ready], MapSet.new([module]))
  end

  defp pushed_payload(socket, event) do
    [^event, payload] =
      Enum.find(socket.private.live_temp.push_events, fn
        [^event, _payload] -> true
        _other -> false
      end)

    payload
  end
end
