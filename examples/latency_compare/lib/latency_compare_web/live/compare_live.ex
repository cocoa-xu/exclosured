defmodule LatencyCompareWeb.CompareLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       mode: "wasm",
       brightness: 0,
       contrast: 0,
       wasm_ready: false,
       round_trip_ms: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Latency Comparison</h1>
    <p class="desc">
      Drag the sliders and feel the difference. In Local WASM mode, the filter runs
      instantly in your browser. In Server Roundtrip mode, every slider change travels
      to the server and back before the filter is applied.
    </p>

    <div class="mode-toggle">
      <button
        class={"mode-btn #{if @mode == "server", do: "active", else: ""}"}
        phx-click="set_mode"
        phx-value-mode="server"
      >
        Server Roundtrip
      </button>
      <button
        class={"mode-btn #{if @mode == "wasm", do: "active", else: ""}"}
        phx-click="set_mode"
        phx-value-mode="wasm"
      >
        Local WASM
      </button>
    </div>

    <form phx-change="update_filter">
      <div class="sliders">
        <div class="slider-group">
          <label>
            Brightness: <span class="slider-value"><%= @brightness %></span>
          </label>
          <input
            type="range"
            name="brightness"
            min="-100"
            max="100"
            value={@brightness}
            id="brightness-slider"
          />
        </div>
        <div class="slider-group">
          <label>
            Contrast: <span class="slider-value"><%= @contrast %></span>
          </label>
          <input
            type="range"
            name="contrast"
            min="-100"
            max="100"
            value={@contrast}
            id="contrast-slider"
          />
        </div>
      </div>
    </form>

    <div
      id="compare-canvas"
      phx-hook="Compare"
      phx-update="ignore"
      data-mode={@mode}
      class="canvas-wrap"
    >
      <canvas id="filter-canvas" width="256" height="256"></canvas>
    </div>

    <div class="latency-bar">
      <div class="label">
        <%= if @mode == "wasm", do: "Local WASM latency", else: "Server round-trip latency" %>
      </div>
      <div class={"value #{latency_class(@mode, @round_trip_ms)}"}>
        <%= if @round_trip_ms do %>
          <%= @round_trip_ms %><span class="unit"> ms</span>
        <% else %>
          --<span class="unit"> ms</span>
        <% end %>
      </div>
      <div class="hint">
        <%= if @mode == "wasm" do %>
          Filter runs directly in WASM -- no network involved
        <% else %>
          Slider value travels: browser -> server -> browser -> WASM -> canvas
        <% end %>
      </div>
    </div>

    <p :if={!@wasm_ready} class="loading">Loading WASM module...</p>
    """
  end

  defp latency_class("wasm", ms) when is_number(ms) and ms < 5, do: "fast"
  defp latency_class("wasm", _), do: "fast"
  defp latency_class("server", ms) when is_number(ms) and ms < 20, do: "fast"
  defp latency_class("server", ms) when is_number(ms), do: "slow"
  defp latency_class(_, _), do: "none"

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ~w(wasm server) do
    {:noreply, assign(socket, mode: mode, round_trip_ms: nil)}
  end

  def handle_event("wasm:ready", _params, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_event("update_filter", params, socket) do
    brightness = parse_int(params["brightness"], socket.assigns.brightness)
    contrast = parse_int(params["contrast"], socket.assigns.contrast)

    socket = assign(socket, brightness: brightness, contrast: contrast)

    # In server mode, bounce the values back to the client so it can
    # apply the filter. The round-trip IS the point of the demo.
    socket =
      if socket.assigns.mode == "server" do
        push_event(socket, "server:filter_result", %{
          brightness: brightness,
          contrast: contrast
        })
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("report_latency", %{"ms" => ms}, socket) do
    {:noreply, assign(socket, round_trip_ms: ms)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
