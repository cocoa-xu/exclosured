if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule Exclosured.Test do
    @moduledoc """
    Helpers for testing Exclosured-driven LiveView flows without a browser.

    The helpers deliver the same `handle_info/2` messages produced by
    `Exclosured.LiveView` after browser hook events. When given a
    `Phoenix.LiveViewTest.View`, they return the rendered HTML after the
    message is sent. When given a pid, they send the message and return `:ok`.
    """

    alias Phoenix.LiveViewTest.View

    @type target :: %View{} | pid()

    @doc """
    Mark a WASM module as ready.

        Exclosured.Test.ready(view, :processor)

    Sends `{:wasm_ready, module}`.
    """
    @spec ready(target(), atom()) :: String.t() | :ok | {:error, term()}
    def ready(target, module) when is_atom(module) do
      dispatch(target, {:wasm_ready, module})
    end

    @doc """
    Deliver a legacy WASM result message.

        Exclosured.Test.result(view, :processor, "score", 42)

    Sends `{:wasm_result, module, func, result}`.
    """
    @spec result(target(), atom(), String.t(), term()) :: String.t() | :ok | {:error, term()}
    def result(target, module, func, result) when is_atom(module) and is_binary(func) do
      dispatch(target, {:wasm_result, module, func, result})
    end

    @doc """
    Deliver a correlated WASM result message.

        Exclosured.Test.result(view, ref, :processor, "score", 42)

    Sends `{:wasm_result, ref, module, func, result}`.
    """
    @spec result(target(), term(), atom(), String.t(), term()) ::
            String.t() | :ok | {:error, term()}
    def result(target, ref, module, func, result) when is_atom(module) and is_binary(func) do
      dispatch(target, {:wasm_result, to_string(ref), module, func, result})
    end

    @doc """
    Deliver a WASM emit message.

        Exclosured.Test.emit(view, :processor, "progress", %{"percent" => 50})

    Sends `{:wasm_emit, module, event, payload}`.
    """
    @spec emit(target(), atom(), String.t(), term()) :: String.t() | :ok | {:error, term()}
    def emit(target, module, event, payload) when is_atom(module) and is_binary(event) do
      dispatch(target, {:wasm_emit, module, event, payload})
    end

    @doc """
    Deliver a legacy WASM error message.

        Exclosured.Test.error(view, :processor, "score", "boom")

    Sends `{:wasm_error, module, func, reason}`.
    """
    @spec error(target(), atom(), String.t(), term()) :: String.t() | :ok | {:error, term()}
    def error(target, module, func, reason) when is_atom(module) and is_binary(func) do
      dispatch(target, {:wasm_error, module, func, reason})
    end

    @doc """
    Deliver a correlated WASM error message.

        Exclosured.Test.error(view, ref, :processor, "score", "boom")

    Sends `{:wasm_error, ref, module, func, reason}`.
    """
    @spec error(target(), term(), atom(), String.t(), term()) ::
            String.t() | :ok | {:error, term()}
    def error(target, ref, module, func, reason) when is_atom(module) and is_binary(func) do
      dispatch(target, {:wasm_error, to_string(ref), module, func, reason})
    end

    defp dispatch(%View{pid: pid} = view, message) when is_pid(pid) do
      send(pid, message)
      Phoenix.LiveViewTest.render(view)
    end

    defp dispatch(pid, message) when is_pid(pid) do
      send(pid, message)
      :ok
    end
  end
end
