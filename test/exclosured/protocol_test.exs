defmodule Exclosured.ProtocolTest do
  use ExUnit.Case

  alias Exclosured.Protocol

  describe "encode/decode roundtrip" do
    test "integer" do
      assert 42 == Protocol.decode(Protocol.encode(42))
      assert -1 == Protocol.decode(Protocol.encode(-1))
      assert 0 == Protocol.decode(Protocol.encode(0))
    end

    test "float" do
      assert 3.14 == Protocol.decode(Protocol.encode(3.14))
      assert -0.5 == Protocol.decode(Protocol.encode(-0.5))
    end

    test "string" do
      assert "hello" == Protocol.decode(Protocol.encode("hello"))
      assert "" == Protocol.decode(Protocol.encode(""))
    end

    test "boolean" do
      assert true == Protocol.decode(Protocol.encode(true))
      assert false == Protocol.decode(Protocol.encode(false))
    end

    test "nil" do
      assert nil == Protocol.decode(Protocol.encode(nil))
    end

    test "atom" do
      assert :ok == Protocol.decode(Protocol.encode(:ok))
      assert :error == Protocol.decode(Protocol.encode(:error))
    end

    test "list" do
      assert [1, 2, 3] == Protocol.decode(Protocol.encode([1, 2, 3]))
      assert [] == Protocol.decode(Protocol.encode([]))
      assert ["a", 1, true] == Protocol.decode(Protocol.encode(["a", 1, true]))
    end

    test "map" do
      original = %{"x" => 1.0, "y" => 2.0, "z" => 3.0}
      assert original == Protocol.decode(Protocol.encode(original))
    end

    test "nested structures" do
      original = %{
        "players" => [
          %{"id" => 1, "pos" => [10.0, 20.0]},
          %{"id" => 2, "pos" => [30.0, 40.0]}
        ],
        "tick" => 42
      }

      assert original == Protocol.decode(Protocol.encode(original))
    end
  end
end
