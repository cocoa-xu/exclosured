defmodule Exclosured.LiveViewTest do
  use ExUnit.Case

  alias Exclosured.LiveView

  describe "sync/2" do
    test "same-name shorthand with atom list" do
      assigns = %{frequency: 5, amplitude: 80, speed: 50}

      result = LiveView.sync(assigns, [:frequency, :amplitude, :speed])

      assert result == %{frequency: 5, amplitude: 80, speed: 50}
    end

    test "same-name shorthand with ~w sigil" do
      assigns = %{x: 1, y: 2, z: 3}

      result = LiveView.sync(assigns, ~w(x y z)a)

      assert result == %{x: 1, y: 2, z: 3}
    end

    test "renamed keys with keyword pairs" do
      assigns = %{wave_type: "sine", shape_count: 10}

      result = LiveView.sync(assigns, wave: :wave_type, shapes: :shape_count)

      assert result == %{wave: "sine", shapes: 10}
    end

    test "mixed same-name and renamed keys" do
      assigns = %{frequency: 5, amplitude: 80, speed: 50, color: "#ff0000", wave_type: "sine"}

      result =
        LiveView.sync(assigns, [:frequency, :amplitude, :speed, :color, wave: :wave_type])

      assert result == %{
               frequency: 5,
               amplitude: 80,
               speed: 50,
               color: "#ff0000",
               wave: "sine"
             }
    end

    test "missing keys return nil" do
      assigns = %{frequency: 5}

      result = LiveView.sync(assigns, [:frequency, :missing_key])

      assert result == %{frequency: 5, missing_key: nil}
    end

    test "empty list returns empty map" do
      assert LiveView.sync(%{x: 1}, []) == %{}
    end

    test "renamed key with missing assign returns nil" do
      assigns = %{frequency: 5}

      result = LiveView.sync(assigns, [:frequency, wasm_amp: :amplitude])

      assert result == %{frequency: 5, wasm_amp: nil}
    end

    test "all renamed keys" do
      assigns = %{frequency: 5, amplitude: 80}

      result = LiveView.sync(assigns, freq: :frequency, amp: :amplitude)

      assert result == %{freq: 5, amp: 80}
    end

    test "preserves value types" do
      assigns = %{count: 42, label: "hello", ratio: 3.14, active: true, data: nil}

      result = LiveView.sync(assigns, [:count, :label, :ratio, :active, :data])

      assert result == %{count: 42, label: "hello", ratio: 3.14, active: true, data: nil}
    end
  end

  describe "wasm_ready?/2" do
    test "returns false when no modules are ready" do
      socket = build_socket()
      refute Exclosured.LiveView.wasm_ready?(socket, :my_mod)
    end

    test "returns true after module is marked ready" do
      socket = build_socket()
      ready = MapSet.new([:my_mod])
      socket = put_in(socket, [Access.key(:private), :exclosured_ready], ready)
      assert Exclosured.LiveView.wasm_ready?(socket, :my_mod)
    end

    test "returns false for a different module" do
      socket = build_socket()
      ready = MapSet.new([:other_mod])
      socket = put_in(socket, [Access.key(:private), :exclosured_ready], ready)
      refute Exclosured.LiveView.wasm_ready?(socket, :my_mod)
    end
  end

  describe "call/5 with fallback" do
    test "runs fallback when WASM is not ready" do
      socket = build_socket()

      # call with fallback, WASM not ready
      _socket =
        Exclosured.LiveView.call(socket, :my_mod, "count", ["hello world"],
          fallback: fn [text] -> length(String.split(text)) end
        )

      # Fallback sends the result as if WASM returned it
      assert_receive {:wasm_result, :my_mod, "count", 2}
    end

    test "fallback result matches WASM result shape" do
      socket = build_socket()

      _socket =
        Exclosured.LiveView.call(socket, :my_mod, "process", [42],
          fallback: fn [n] -> n * 2 end
        )

      assert_receive {:wasm_result, :my_mod, "process", 84}
    end
  end

  describe "stream_call/5" do
    test "requires :on_chunk option" do
      assert_raise KeyError, ~r/key :on_chunk not found/, fn ->
        LiveView.stream_call(build_socket(), :mod, "func", [], [])
      end
    end

    test "accepts :on_chunk and optional :on_done" do
      # Can't fully test without a connected LiveView, but we can verify
      # the function exists and validates options
      assert_raise KeyError, ~r/on_chunk/, fn ->
        LiveView.stream_call(build_socket(), :mod, "func", [], on_done: fn s -> s end)
      end
    end
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }
  end
end
