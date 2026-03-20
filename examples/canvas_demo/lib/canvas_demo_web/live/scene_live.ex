defmodule CanvasDemoWeb.SceneLive do
  use Phoenix.LiveView

  @topic "canvas:sync"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       wasm_ready: false,
       sync: false,
       speed: 50,
       color: "#00d2ff",
       shape_count: 5
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Interactive Canvas Demo</h1>
    <p class="desc">
      A Rust WASM module renders to a Canvas element at 60fps using
      wasm-bindgen + web-sys. LiveView pushes parameter updates to
      WASM without interrupting the render loop.
    </p>

    <form phx-change="update_controls" class="controls">
      <label>
        Speed: <%= @speed %>
        <input type="range" min="1" max="100" value={@speed} name="speed" />
      </label>
      <label>
        Shapes: <%= @shape_count %>
        <input type="range" min="1" max="20" value={@shape_count} name="count" />
      </label>
      <label>
        Color:
        <input type="color" value={@color} name="color" />
      </label>
    </form>

    <div class="sync-toggle">
      <label>
        <input type="checkbox" checked={@sync} phx-click="toggle_sync" />
        Sync with other users
      </label>
    </div>

    <div
      id="wasm-renderer"
      phx-hook="Exclosured"
      data-wasm-module="renderer"

      data-wasm-width="800"
      data-wasm-height="500"
    >
      <canvas width="800" height="500"></canvas>
    </div>

    <p :if={!@wasm_ready} class="status">Loading WASM renderer...</p>
    <p :if={@wasm_ready && !@sync} class="status">Rendering at 60fps in WASM (local only)</p>
    <p :if={@wasm_ready && @sync} class="status">Rendering at 60fps in WASM (synced with other users)</p>
    """
  end

  @impl true
  def handle_event("update_controls", params, socket) do
    socket =
      socket
      |> maybe_assign_int(params, "speed", :speed)
      |> maybe_assign_int(params, "count", :shape_count)
      |> maybe_assign_string(params, "color", :color)
      |> push_scene_state()
      |> maybe_broadcast()

    {:noreply, socket}
  end

  def handle_event("toggle_sync", _params, socket) do
    sync = !socket.assigns.sync

    if sync do
      Phoenix.PubSub.subscribe(CanvasDemo.PubSub, @topic)
    else
      Phoenix.PubSub.unsubscribe(CanvasDemo.PubSub, @topic)
    end

    {:noreply, assign(socket, sync: sync)}
  end

  def handle_event("wasm:ready", %{"module" => "renderer"}, socket) do
    socket =
      socket
      |> assign(wasm_ready: true)
      |> push_scene_state()

    {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:scene_sync, sender, state}, socket) do
    if sender != self() do
      socket =
        socket
        |> assign(speed: state.speed, shape_count: state.shape_count, color: state.color)
        |> push_scene_state()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:wasm_ready, :renderer}, socket) do
    socket =
      socket
      |> assign(wasm_ready: true)
      |> push_scene_state()

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp maybe_broadcast(socket) do
    if socket.assigns.sync do
      Phoenix.PubSub.broadcast(CanvasDemo.PubSub, @topic, {
        :scene_sync,
        self(),
        %{
          speed: socket.assigns.speed,
          shape_count: socket.assigns.shape_count,
          color: socket.assigns.color
        }
      })
    end

    socket
  end

  defp maybe_assign_int(socket, params, key, assign_key) do
    case params[key] do
      nil -> socket
      val -> assign(socket, [{assign_key, String.to_integer(val)}])
    end
  end

  defp maybe_assign_string(socket, params, key, assign_key) do
    case params[key] do
      nil -> socket
      val -> assign(socket, [{assign_key, val}])
    end
  end

  defp push_scene_state(socket) do
    Phoenix.LiveView.push_event(socket, "wasm:state", %{
      speed: socket.assigns.speed,
      shape_count: socket.assigns.shape_count,
      color: socket.assigns.color
    })
  end
end
