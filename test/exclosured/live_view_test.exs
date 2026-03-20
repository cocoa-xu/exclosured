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
end
