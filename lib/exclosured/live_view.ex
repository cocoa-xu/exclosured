if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Exclosured.LiveView do
    @moduledoc """
    LiveView integration for Exclosured WASM modules.

    Provides `call/5` to invoke WASM functions from a LiveView process,
    and `sandbox/1` as a HEEx component for embedding WASM modules.

    ## Declarative State Sync

    The `sandbox` component supports a `sync` attribute that automatically
    pushes assign changes to the WASM module:

        <Exclosured.LiveView.sandbox
          module={:renderer}
          sync={%{speed: @speed, color: @color}}
          canvas
        />

    When `@speed` or `@color` changes, the new values are automatically
    pushed to the WASM module via `wasm:state`. No manual `push_event`
    calls needed.

    ## Manual Usage

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

    require Logger

    @doc """
    Build a sync map from assigns using a list of keys.

    Shorthand for building the `sync` attribute on the `sandbox` component.
    Bare atoms use the same name as the assign key. Keyword pairs map an
    assign to a different key name.

        <%# Same-name shorthand: %>
        sync={sync(assigns, ~w(frequency amplitude speed)a)}

        <%# Mixed: four same-name, one renamed: %>
        sync={sync(assigns, [:frequency, :amplitude, :speed, :color, wave: :wave_type])}

        <%# The above produces: %>
        %{frequency: @frequency, amplitude: @amplitude, speed: @speed,
          color: @color, wave: @wave_type}
    """
    def sync(assigns, keys) when is_list(keys) do
      Map.new(keys, fn
        {target_key, assign_key} -> {target_key, assigns[assign_key]}
        key when is_atom(key) -> {key, assigns[key]}
      end)
    end

    @doc """
    Call a WASM function on the client. The result will arrive as a
    `{:wasm_result, module, func, result}` message via `handle_info/2`.

    ## Options

      * `:fallback` - a function that receives the args list and returns a result.
        If WASM is not loaded yet, the fallback runs on the server and delivers
        the result via `{:wasm_result, module, func, result}`, the same shape
        as a WASM result. Your `handle_info` works identically either way.

    ## Example

        socket = Exclosured.LiveView.call(socket, :my_mod, "process", [text],
          fallback: fn [text] -> String.split(text) |> length() end
        )

        # This handler works regardless of whether WASM or fallback ran:
        def handle_info({:wasm_result, :my_mod, "process", result}, socket) do
          {:noreply, assign(socket, result: result)}
        end
    """
    def call(socket, module, func, args, opts \\ []) do
      fallback = Keyword.get(opts, :fallback)
      wasm_ready? = wasm_ready?(socket, module)

      if !wasm_ready? && fallback != nil do
        result = fallback.(args)
        Exclosured.Telemetry.wasm_call(module, func)
        Exclosured.Telemetry.wasm_result(module, func)
        send(self(), {:wasm_result, module, func, result})
        socket
      else
        # Either WASM is ready, or no fallback is available.
        # Push the call to the client; it will execute when WASM loads.
        ref = System.unique_integer([:positive]) |> Integer.to_string()
        Exclosured.Telemetry.wasm_call(module, func)

        socket
        |> ensure_wasm_hook()
        |> push_event("wasm:call", %{func: func, args: args, ref: ref})
      end
    end

    @doc """
    Check if a WASM module has reported ready for this socket.
    """
    def wasm_ready?(socket, module) do
      socket.private
      |> Map.get(:exclosured_ready, MapSet.new())
      |> MapSet.member?(module)
    end

    @doc """
    Push a state update to a WASM module.
    """
    def push_state(socket, _module, state) when is_map(state) do
      push_event(socket, "wasm:state", state)
    end

    def push_state(socket, _module, binary) when is_binary(binary) do
      push_event(socket, "wasm:state", %{binary: binary})
    end

    @doc """
    Call a WASM function that streams results back incrementally.

    Instead of waiting for a single `{:wasm_result, ...}` message, this
    sets up handlers for streaming `emit("chunk", ...)` events from WASM.
    Each chunk triggers the `on_chunk` callback. When WASM emits `"done"`,
    the `on_done` callback fires and the stream handler is cleaned up.

    ## Options

      * `:on_chunk` (required) - `fn payload, socket -> socket` called for each chunk
      * `:on_done` - `fn socket -> socket` called when streaming completes (default: identity)
      * `:chunk_event` - event name WASM emits for chunks (default: `"chunk"`)
      * `:done_event` - event name WASM emits on completion (default: `"done"`)

    ## Example

        # In your LiveView:
        def handle_event("analyze", %{"data" => data}, socket) do
          socket =
            socket
            |> Exclosured.LiveView.stream_call(:processor, "analyze", [data],
              on_chunk: fn chunk, socket ->
                update(socket, :results, &[chunk | &1])
              end,
              on_done: fn socket ->
                assign(socket, processing: false)
              end
            )

          {:noreply, assign(socket, processing: true, results: [])}
        end

        # In your Rust WASM:
        # for item in data.chunks(100) {
        #     exclosured::emit("chunk", &process(item));
        # }
        # exclosured::emit("done", "{}");
    """
    def stream_call(socket, module, func, args, opts) do
      on_chunk = Keyword.fetch!(opts, :on_chunk)
      on_done = Keyword.get(opts, :on_done, fn socket -> socket end)
      chunk_event = Keyword.get(opts, :chunk_event, "chunk")
      done_event = Keyword.get(opts, :done_event, "done")

      stream_id = {module, func, System.unique_integer([:positive])}

      socket
      |> call(module, func, args)
      |> attach_hook(
        {:exclosured_stream, stream_id},
        :handle_info,
        fn
          {:wasm_emit, ^module, event, payload}, socket when event == chunk_event ->
            {:halt, on_chunk.(payload, socket)}

          {:wasm_emit, ^module, event, _payload}, socket when event == done_event ->
            socket =
              socket
              |> on_done.()
              |> Phoenix.LiveView.detach_hook({:exclosured_stream, stream_id}, :handle_info)

            {:halt, socket}

          _other, socket ->
            {:cont, socket}
        end
      )
    end

    @doc """
    HEEx component that renders a WASM sandbox container element.

    ## Attributes

      * `module` (required) - The WASM module name (atom)
      * `id` - Element ID (defaults to "wasm-{module}")
      * `sync` - Map of values to auto-sync to WASM on change (default: nil).
        When any value in the map changes between renders, the component
        pushes the entire sync map to the WASM module via `wasm:state`.
      * `canvas` - Whether to include a canvas element (default: false)
      * `width` - Canvas width (default: 800)
      * `height` - Canvas height (default: 600)
      * `subscribe` - List of broadcast channels to subscribe to
      * `class` - CSS class for the container
    """
    attr(:module, :atom, required: true)
    attr(:id, :string, default: nil)
    attr(:sync, :map, default: nil)
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
        |> assign_new(:sync_json, fn ->
          case assigns.sync do
            nil -> nil
            map when is_map(map) -> Jason.encode!(map)
          end
        end)

      ~H"""
      <div
        id={@id || @element_id}
        phx-hook="Exclosured"
        data-wasm-module={@module}
        data-wasm-subscribe={@subscribe_str}
        data-wasm-sync={@sync_json}
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
      e ->
        Logger.error("Exclosured: failed to attach wasm hook: #{Exception.message(e)}")
        socket
    end

    defp handle_wasm_event(
           "wasm:result",
           %{"module" => module, "func" => func, "result" => result},
           socket
         ) do
      with {:ok, mod_atom} <- safe_atom(module) do
        Exclosured.Telemetry.wasm_result(mod_atom, func)
        send(self(), {:wasm_result, mod_atom, func, result})
      end

      {:halt, socket}
    end

    defp handle_wasm_event(
           "wasm:emit",
           %{"module" => module, "event" => event, "payload" => payload},
           socket
         ) do
      with {:ok, mod_atom} <- safe_atom(module) do
        Exclosured.Telemetry.wasm_emit(mod_atom, event)
        send(self(), {:wasm_emit, mod_atom, event, payload})
      end

      {:halt, socket}
    end

    defp handle_wasm_event(
           "wasm:error",
           %{"module" => module, "func" => func, "error" => error},
           socket
         ) do
      with {:ok, mod_atom} <- safe_atom(module) do
        Exclosured.Telemetry.wasm_error(mod_atom, func, error)
        send(self(), {:wasm_error, mod_atom, func, error})
      end

      {:halt, socket}
    end

    defp handle_wasm_event("wasm:ready", %{"module" => module}, socket) do
      with {:ok, mod_atom} <- safe_atom(module) do
        Exclosured.Telemetry.wasm_ready(mod_atom)
        send(self(), {:wasm_ready, mod_atom})

        # Track readiness so call/5 can route to fallback when WASM isn't loaded
        ready = Map.get(socket.private, :exclosured_ready, MapSet.new())

        socket =
          put_in(socket, [Access.key(:private), :exclosured_ready], MapSet.put(ready, mod_atom))

        {:halt, socket}
      else
        _ -> {:halt, socket}
      end
    end

    defp handle_wasm_event(_event, _params, socket) do
      {:cont, socket}
    end

    defp safe_atom(name) when is_binary(name) do
      {:ok, String.to_existing_atom(name)}
    rescue
      ArgumentError -> :error
    end
  end
end
