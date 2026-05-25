defmodule Exclosured.TestHelpersTest do
  use ExUnit.Case, async: true

  alias Exclosured.Test, as: ExclosuredTest

  describe "ready/2" do
    test "sends a wasm_ready message" do
      assert ExclosuredTest.ready(self(), :processor) == :ok

      assert_receive {:wasm_ready, :processor}
    end
  end

  describe "result/4" do
    test "sends a legacy wasm_result message" do
      assert ExclosuredTest.result(self(), :processor, "score", 42) == :ok

      assert_receive {:wasm_result, :processor, "score", 42}
    end
  end

  describe "result/5" do
    test "sends a correlated wasm_result message" do
      assert ExclosuredTest.result(self(), 123, :processor, "score", 42) == :ok

      assert_receive {:wasm_result, "123", :processor, "score", 42}
    end
  end

  describe "emit/4" do
    test "sends a wasm_emit message" do
      payload = %{"percent" => 50}

      assert ExclosuredTest.emit(self(), :processor, "progress", payload) == :ok

      assert_receive {:wasm_emit, :processor, "progress", ^payload}
    end
  end

  describe "error/4" do
    test "sends a legacy wasm_error message" do
      assert ExclosuredTest.error(self(), :processor, "score", "boom") == :ok

      assert_receive {:wasm_error, :processor, "score", "boom"}
    end
  end

  describe "error/5" do
    test "sends a correlated wasm_error message" do
      assert ExclosuredTest.error(self(), "ref-1", :processor, "score", :timeout) == :ok

      assert_receive {:wasm_error, "ref-1", :processor, "score", :timeout}
    end
  end
end
