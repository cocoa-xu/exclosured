if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Exclosured.LiveView do
    @moduledoc """
    LiveView integration for Exclosured WASM modules.

    Provides `call/5` to invoke WASM functions from a LiveView process,
    and `sandbox/1` as a HEEx component for embedding WASM modules.

    ## Usage

        defmodule MyAppWeb.ProcessorLive do
          use Phoenix.LiveView

          def handle_event("run", %{"input" => input}, socket) do
            socket = Exclosured.LiveView.call(socket, :my_mod, "process", [input])
            {:noreply, socket}
          end

          def handle_info({:wasm_result, :my_mod, "process", result}, socket) do
            {:noreply, assign(socket, result: result)}
          end

          def handle_info({:wasm_emit, :my_mod, "progress", payload}, socket) do
            {:noreply, assign(socket, progress: payload)}
          end
        end
    """

    use Phoenix.Component
    import Phoenix.LiveView, only: [push_event: 3, attach_hook: 4, connected?: 1]

    @doc """
    Call a WASM function on the client. The result will arrive as a
    `{:wasm_result, module, func, result}` message via `handle_info/2`.

    ## Options

      * `:timeout` - not enforced server-side, but can be used by the caller
    """
    def call(socket, _module, func, args, _opts \\ []) do
      ref = System.unique_integer([:positive]) |> Integer.to_string()

      socket
      |> ensure_wasm_hook()
      |> push_event("wasm:call", %{
        func: func,
        args: args,
        ref: ref
      })
    end

    @doc """
    Push a state update to an interactive WASM module.
    """
    def push_state(socket, _module, state) when is_map(state) do
      push_event(socket, "wasm:state", state)
    end

    def push_state(socket, _module, binary) when is_binary(binary) do
      push_event(socket, "wasm:state", %{binary: binary})
    end

    @doc """
    HEEx component that renders a WASM sandbox container element.

    ## Attributes

      * `module` (required) - The WASM module name (atom)
      * `id` - Element ID (defaults to "wasm-{module}")
      * `mode` - Execution mode: "compute" or "interactive" (default: "compute")
      * `canvas` - Whether to include a canvas element (default: false)
      * `width` - Canvas width (default: 800)
      * `height` - Canvas height (default: 600)
      * `subscribe` - List of broadcast channels to subscribe to
      * `class` - CSS class for the container
    """
    attr(:module, :atom, required: true)
    attr(:id, :string, default: nil)
    attr(:mode, :string, default: "compute")
    attr(:canvas, :boolean, default: false)
    attr(:width, :integer, default: 800)
    attr(:height, :integer, default: 600)
    attr(:subscribe, :list, default: [])
    attr(:class, :string, default: nil)

    def sandbox(assigns) do
      assigns =
        assigns
        |> assign_new(:element_id, fn -> "wasm-#{assigns.module}" end)
        |> assign_new(:subscribe_str, fn ->
          case assigns.subscribe do
            [] -> nil
            channels -> Enum.join(channels, ",")
          end
        end)

      ~H"""
      <div
        id={@id || @element_id}
        phx-hook="Exclosured"
        data-wasm-module={@module}
        data-wasm-mode={@mode}
        data-wasm-subscribe={@subscribe_str}
        data-wasm-width={if @canvas, do: @width}
        data-wasm-height={if @canvas, do: @height}
        class={@class}
      >
        <canvas :if={@canvas} width={@width} height={@height}></canvas>
      </div>
      """
    end

    defp ensure_wasm_hook(socket) do
      if connected?(socket) && !Map.get(socket.private, :exclosured_hook_attached) do
        socket
        |> attach_hook(:exclosured, :handle_event, &handle_wasm_event/3)
        |> put_in([Access.key(:private), :exclosured_hook_attached], true)
      else
        socket
      end
    rescue
      _ -> socket
    end

    defp handle_wasm_event(
           "wasm:result",
           %{"ref" => _ref, "module" => module, "func" => func, "result" => result},
           socket
         ) do
      mod_atom = String.to_existing_atom(module)
      send(self(), {:wasm_result, mod_atom, func, result})
      {:halt, socket}
    end

    defp handle_wasm_event(
           "wasm:emit",
           %{"module" => module, "event" => event, "payload" => payload},
           socket
         ) do
      mod_atom = String.to_existing_atom(module)
      send(self(), {:wasm_emit, mod_atom, event, payload})
      {:halt, socket}
    end

    defp handle_wasm_event(
           "wasm:error",
           %{"module" => module, "func" => func, "error" => error},
           socket
         ) do
      mod_atom = String.to_existing_atom(module)
      send(self(), {:wasm_error, mod_atom, func, error})
      {:halt, socket}
    end

    defp handle_wasm_event("wasm:ready", %{"module" => module}, socket) do
      mod_atom = String.to_existing_atom(module)
      send(self(), {:wasm_ready, mod_atom})
      {:halt, socket}
    end

    defp handle_wasm_event(_event, _params, socket) do
      {:cont, socket}
    end
  end
end
