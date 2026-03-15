defmodule RealtimeSyncWeb.CursorLive do
  @moduledoc """
  Collaborative image editor.

  State flow:
  - Image snapshot (compressed RGBA) lives in RealtimeSync.Room
  - Drawing ops are broadcast via PubSub and stored in Room
  - Each client's WASM holds the local pixel buffer (source of truth for rendering)
  - New joiners receive snapshot + ops to reconstruct current state
  - Filters bake a new snapshot (client sends updated pixels to Room)
  """

  use Phoenix.LiveView

  @topic "collab:room"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RealtimeSync.PubSub, @topic)
    end

    {:ok,
     assign(socket,
       wasm_ready: false,
       has_image: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="header">
      <h1>Confidential Collab Editor</h1>
      <p class="desc">
        All image processing happens in your browser's <strong>WASM sandbox</strong>.
        Drawing and filters are applied locally, then synced to all users via LiveView.
      </p>
    </div>

    <div class="toolbar" id="toolbar" phx-update="ignore">
      <div class="tool-group">
        <button id="btn-pen" class="tool active" data-tool="pen">Pen</button>
        <button id="btn-eraser" class="tool" data-tool="eraser">Eraser</button>
      </div>
      <div class="tool-group">
        <label>Color <input type="color" id="pen-color" value="#ff6b6b" /></label>
        <label>Size <input type="range" id="pen-size" min="1" max="30" value="4" /></label>
      </div>
      <div class="tool-group filters">
        <span class="label">WASM Filters:</span>
        <button class="filter-btn" data-filter="grayscale">Grayscale</button>
        <button class="filter-btn" data-filter="invert">Invert</button>
        <button class="filter-btn" data-filter="sepia">Sepia</button>
        <button class="filter-btn" data-filter="brightness">Brighten</button>
        <button class="filter-btn" data-filter="blur">Blur</button>
      </div>
    </div>

    <div id="editor" phx-hook="CollabEditor" phx-update="ignore">
      <canvas id="canvas" width="800" height="500"></canvas>
      <div id="drop-zone" class="drop-zone">
        <p>Select or drop an image to start</p>
        <input type="file" id="file-input" accept="image/*" />
      </div>
    </div>

    <div class="status-bar">
      <div class="connection-info">
        <span class={"indicator #{if @has_image, do: "connected", else: "waiting"}"}></span>
        <%= if @has_image, do: "Editing live", else: "No image loaded" %>
      </div>
      <div class="wasm-badge">
        <%= if @wasm_ready, do: "WASM ready", else: "Loading WASM..." %>
      </div>
    </div>
    """
  end

  # --- Client events ---

  @impl true
  def handle_event("wasm:ready", _params, socket) do
    # WASM loaded, send current room state if any
    socket = assign(socket, wasm_ready: true)
    send(self(), :send_room_state)
    {:noreply, socket}
  end

  # Client uploaded image chunks (base64-encoded compressed RGBA)
  def handle_event("upload_image", %{"data" => b64_data}, socket) do
    data = Base.decode64!(b64_data)
    RealtimeSync.Room.set_image(data)
    {:noreply, assign(socket, has_image: true)}
  end

  # Client applied a filter and is sending the baked snapshot
  def handle_event("bake_snapshot", %{"data" => b64_data}, socket) do
    data = Base.decode64!(b64_data)
    RealtimeSync.Room.bake_snapshot(data)
    {:noreply, socket}
  end

  # Drawing stroke from client, broadcast to all others
  def handle_event("draw", params, socket) do
    op = Map.take(params, ["x0", "y0", "x1", "y1", "r", "g", "b", "a", "size", "eraser"])
    RealtimeSync.Room.add_op(op)

    Phoenix.PubSub.broadcast_from(
      RealtimeSync.PubSub,
      self(),
      @topic,
      {:draw, op}
    )

    {:noreply, socket}
  end

  # Filter command from client, broadcast to all others
  def handle_event("apply_filter", %{"name" => name}, socket) do
    Phoenix.PubSub.broadcast_from(
      RealtimeSync.PubSub,
      self(),
      @topic,
      {:filter, name}
    )

    {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  # --- PubSub messages ---

  @impl true
  # Room image was updated (by another user uploading)
  def handle_info(:state_updated, socket) do
    send(self(), :send_room_state)
    {:noreply, assign(socket, has_image: true)}
  end

  # Drawing stroke from another user
  def handle_info({:draw, op}, socket) do
    socket = Phoenix.LiveView.push_event(socket, "remote_draw", op)
    {:noreply, socket}
  end

  # Filter from another user
  def handle_info({:filter, name}, socket) do
    socket = Phoenix.LiveView.push_event(socket, "remote_filter", %{name: name})
    {:noreply, socket}
  end

  # Send current room state to this client
  def handle_info(:send_room_state, socket) do
    if socket.assigns.wasm_ready do
      state = RealtimeSync.Room.get_state()

      socket =
        if state.image do
          b64 = Base.encode64(state.image)

          socket
          |> Phoenix.LiveView.push_event("load_snapshot", %{data: b64})
          |> push_ops(state.ops)
          |> assign(has_image: true)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp push_ops(socket, []), do: socket

  defp push_ops(socket, ops) do
    Enum.reduce(ops, socket, fn op, sock ->
      Phoenix.LiveView.push_event(sock, "remote_draw", op)
    end)
  end
end
