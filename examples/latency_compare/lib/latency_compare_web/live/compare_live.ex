defmodule LatencyCompareWeb.CompareLive do
  use Phoenix.LiveView

  @vix_loaded Code.ensure_loaded?(Vix.Vips.Image)
  @evision_loaded Code.ensure_loaded?(Evision.Mat)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       mode: "wasm",
       brightness: 0,
       contrast: 0,
       wasm_ready: false,
       round_trip_ms: nil,
       server_compute_ms: nil,
       original_pixels: nil,
       img_width: 256,
       img_height: 256,
       vix_available: @vix_loaded,
       evision_available: @evision_loaded
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Latency Comparison</h1>
    <p class="desc">
      Drag the sliders and compare. Local modes (JS, WASM) run instantly in your browser.
      Server modes send pixels to the server and back, showing the network cost.
    </p>

    <div class="mode-toggle">
      <button
        class={"mode-btn #{if @mode == "js", do: "active"}"}
        phx-click="set_mode"
        phx-value-mode="js"
      >
        Pure JS
      </button>
      <button
        class={"mode-btn #{if @mode == "wasm", do: "active"}"}
        phx-click="set_mode"
        phx-value-mode="wasm"
      >
        WASM
      </button>
      <button
        class={"mode-btn #{if @mode == "vix", do: "active"}"}
        phx-click="set_mode"
        phx-value-mode="vix"
        disabled={!@vix_available}
      >
        Server (Vix)
      </button>
      <button
        class={"mode-btn #{if @mode == "evision", do: "active"}"}
        phx-click="set_mode"
        phx-value-mode="evision"
        disabled={!@evision_available}
      >
        Server (evision)
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
      <div class="label"><%= mode_label(@mode) %></div>
      <div class={"value #{latency_class(@mode, @round_trip_ms)}"}>
        <%= if @round_trip_ms do %>
          <%= @round_trip_ms %><span class="unit"> ms</span>
        <% else %>
          --<span class="unit"> ms</span>
        <% end %>
      </div>
      <div :if={@server_compute_ms && @mode in ~w(vix evision)} class="server-compute">
        Server compute: <%= @server_compute_ms %><span class="unit"> ms</span>
      </div>
      <div class="hint"><%= mode_hint(@mode) %></div>
    </div>

    <p :if={!@wasm_ready} class="loading">Loading WASM module...</p>
    """
  end

  defp mode_label("js"), do: "Pure JS latency"
  defp mode_label("wasm"), do: "WASM latency"
  defp mode_label("vix"), do: "Server (Vix) round-trip"
  defp mode_label("evision"), do: "Server (evision) round-trip"
  defp mode_label(_), do: "Latency"

  defp mode_hint("js"), do: "Filter runs in a JavaScript pixel loop, no network involved"
  defp mode_hint("wasm"), do: "Filter runs in compiled WASM, no network involved"

  defp mode_hint("vix"),
    do: "Image sent to server, filtered with libvips (C), returned to browser"

  defp mode_hint("evision"),
    do: "Image sent to server, filtered with OpenCV (C++), returned to browser"

  defp mode_hint(_), do: ""

  defp latency_class(mode, ms) when mode in ~w(js wasm) and is_number(ms), do: "fast"

  defp latency_class(mode, ms) when mode in ~w(vix evision) and is_number(ms) and ms < 20,
    do: "fast"

  defp latency_class(mode, ms) when mode in ~w(vix evision) and is_number(ms), do: "slow"
  defp latency_class(_, _), do: "none"

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ~w(js wasm vix evision) do
    {:noreply, assign(socket, mode: mode, round_trip_ms: nil, server_compute_ms: nil)}
  end

  def handle_event("wasm:ready", _params, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_event(
        "upload_image",
        %{"pixels" => base64_pixels, "width" => w, "height" => h},
        socket
      ) do
    pixels = Base.decode64!(base64_pixels)
    {:noreply, assign(socket, original_pixels: pixels, img_width: w, img_height: h)}
  end

  def handle_event("update_filter", params, socket) do
    brightness = parse_int(params["brightness"], socket.assigns.brightness)
    contrast = parse_int(params["contrast"], socket.assigns.contrast)
    socket = assign(socket, brightness: brightness, contrast: contrast)

    socket =
      if socket.assigns.mode in ~w(vix evision) && socket.assigns.original_pixels do
        apply_server_filter(socket, socket.assigns.mode, brightness, contrast)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("report_latency", params, socket) do
    {:noreply,
     assign(socket,
       round_trip_ms: params["ms"],
       server_compute_ms: params["server_compute_ms"]
     )}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  # Server-side image filtering

  defp apply_server_filter(socket, mode, brightness, contrast) do
    pixels = socket.assigns.original_pixels
    w = socket.assigns.img_width
    h = socket.assigns.img_height

    start = System.monotonic_time(:microsecond)
    filtered = do_filter(mode, pixels, w, h, brightness, contrast)
    elapsed_us = System.monotonic_time(:microsecond) - start

    push_event(socket, "server:filter_result", %{
      pixels: Base.encode64(filtered),
      mode: mode,
      server_time_us: elapsed_us
    })
  end

  if @vix_loaded do
    defp do_filter("vix", pixels, width, height, brightness, contrast) do
      {:ok, img} =
        Vix.Vips.Image.new_from_binary(pixels, width, height, 4, :VIPS_FORMAT_UCHAR)

      c_factor = (contrast + 100) / 100
      b_offset = 127.5 * (1 - c_factor) + brightness * 2.55

      {:ok, result} = Vix.Vips.Operation.linear(img, [c_factor], [b_offset])
      {:ok, result} = Vix.Vips.Operation.cast(result, :VIPS_FORMAT_UCHAR)

      {:ok, binary} = Vix.Vips.Image.write_to_binary(result)
      binary
    end
  end

  if @evision_loaded do
    defp do_filter("evision", pixels, width, height, brightness, contrast) do
      mat = Evision.Mat.from_binary(pixels, {:u, 8}, height, width, 4)

      alpha = (contrast + 100) / 100
      beta = 127.5 * (1 - alpha) + brightness * 2.55

      result = Evision.convertScaleAbs(mat, alpha: alpha, beta: beta)
      Evision.Mat.to_binary(result)
    end
  end

  defp do_filter(_, pixels, _, _, _, _), do: pixels

  # Helpers

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
