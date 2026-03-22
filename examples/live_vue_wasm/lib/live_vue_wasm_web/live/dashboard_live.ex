defmodule LiveVueWasmWeb.DashboardLive do
  use Phoenix.LiveView
  use LiveVue
  use LiveVue.Components, vue_root: ["./assets/vue"]

  @tick_interval 500
  @max_points 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @tick_interval)
    end

    {:ok,
     assign(socket,
       data_points: [],
       running: true,
       wasm_ready: false,
       tick_count: 0
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Real-time Statistics Dashboard</h1>
    <p class="subtitle">
      LiveVue + Exclosured WASM: sensor data computed in the browser
    </p>

    <div class="controls">
      <button
        :if={@running}
        phx-click="stop"
        class="btn-stop"
      >
        Stop
      </button>
      <button
        :if={!@running}
        phx-click="start"
        class="btn-start"
      >
        Start
      </button>
      <button phx-click="reset" class="btn-reset">
        Reset
      </button>

      <span :if={@running} class="status-badge running">
        Streaming data
      </span>
      <span :if={!@running && length(@data_points) > 0} class="status-badge stopped">
        Paused
      </span>
      <span :if={!@wasm_ready} class="status-badge loading">
        Loading WASM...
      </span>
    </div>

    <.vue
      v-component="StatsChart"
      data={Jason.encode!(@data_points)}
      running={@running}
      v-socket={@socket}
    />

    <div class="wasm-info">
      <strong>How it works:</strong>
      LiveView pushes a new simulated sensor reading every 500ms.
      The Vue component receives the data via props, sends the full array
      to a WASM module (<code>defwasm</code> inline Rust), which computes
      count, mean, min, max, standard deviation, and percentiles (p50, p90, p99).
      Vue reactively renders both the line chart and the stats panel.
    </div>
    """
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.running do
      Process.send_after(self(), :tick, @tick_interval)
    end

    # Simulate a sensor reading: a sine wave with noise
    tick = socket.assigns.tick_count
    base = :math.sin(tick * 0.1) * 20 + 50
    noise = (:rand.uniform() - 0.5) * 15
    value = Float.round(base + noise, 2)

    data_points =
      (socket.assigns.data_points ++ [value])
      |> Enum.take(-@max_points)

    {:noreply,
     assign(socket,
       data_points: data_points,
       tick_count: tick + 1
     )}
  end

  @impl true
  def handle_event("stop", _params, socket) do
    {:noreply, assign(socket, running: false)}
  end

  def handle_event("start", _params, socket) do
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, assign(socket, running: true)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, assign(socket, data_points: [], tick_count: 0)}
  end

  def handle_event("wasm:ready", _params, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}
end
