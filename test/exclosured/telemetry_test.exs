defmodule Exclosured.TelemetryTest do
  use ExUnit.Case

  alias Exclosured.Telemetry

  setup do
    # Attach a handler that sends events to the test process
    ref = make_ref()
    test_pid = self()

    handler_id = "test-handler-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      [
        [:exclosured, :compile, :start],
        [:exclosured, :compile, :stop],
        [:exclosured, :compile, :error],
        [:exclosured, :wasm, :call],
        [:exclosured, :wasm, :result],
        [:exclosured, :wasm, :emit],
        [:exclosured, :wasm, :error],
        [:exclosured, :wasm, :ready]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "compile events" do
    test "compile_start emits event with module name" do
      Telemetry.compile_start(:my_mod)

      assert_receive {:telemetry, [:exclosured, :compile, :start], %{system_time: _}, %{module: :my_mod}}
    end

    test "compile_stop emits event with duration and wasm_size" do
      start_time = System.monotonic_time()
      Telemetry.compile_stop(:my_mod, start_time, wasm_size: 1024)

      assert_receive {:telemetry, [:exclosured, :compile, :stop], %{duration: duration},
                       %{module: :my_mod, wasm_size: 1024}}

      assert is_integer(duration)
      assert duration >= 0
    end

    test "compile_error emits event with error message" do
      start_time = System.monotonic_time()
      Telemetry.compile_error(:my_mod, start_time, "cargo failed")

      assert_receive {:telemetry, [:exclosured, :compile, :error], %{duration: _},
                       %{module: :my_mod, error: "cargo failed"}}
    end
  end

  describe "wasm events" do
    test "wasm_call emits event" do
      Telemetry.wasm_call(:my_mod, "process")

      assert_receive {:telemetry, [:exclosured, :wasm, :call], %{},
                       %{module: :my_mod, func: "process"}}
    end

    test "wasm_result emits event" do
      Telemetry.wasm_result(:my_mod, "process")

      assert_receive {:telemetry, [:exclosured, :wasm, :result], %{},
                       %{module: :my_mod, func: "process"}}
    end

    test "wasm_emit emits event" do
      Telemetry.wasm_emit(:my_mod, "progress")

      assert_receive {:telemetry, [:exclosured, :wasm, :emit], %{},
                       %{module: :my_mod, event: "progress"}}
    end

    test "wasm_error emits event" do
      Telemetry.wasm_error(:my_mod, "process", "function not found")

      assert_receive {:telemetry, [:exclosured, :wasm, :error], %{},
                       %{module: :my_mod, func: "process", error: "function not found"}}
    end

    test "wasm_ready emits event" do
      Telemetry.wasm_ready(:my_mod)

      assert_receive {:telemetry, [:exclosured, :wasm, :ready], %{}, %{module: :my_mod}}
    end
  end
end
