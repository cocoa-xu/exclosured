defmodule SyncDemoWeb.WaveLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       frequency: 5,
       amplitude: 80,
       speed: 50,
       color: "#00d2ff",
       wave_type: "sine",
       wasm_ready: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Wave Visualizer</h1>
    <p class="subtitle">Declarative state sync: LiveView assigns flow to WASM automatically.</p>

    <div class="controls-section">
      <form phx-change="update_params">
        <div class="controls-row">
          <div class="control-group">
            <label>Frequency <span class="value"><%= @frequency %></span></label>
            <input type="range" min="1" max="20" value={@frequency} name="frequency" />
          </div>
          <div class="control-group">
            <label>Amplitude <span class="value"><%= @amplitude %></span></label>
            <input type="range" min="10" max="200" value={@amplitude} name="amplitude" />
          </div>
          <div class="control-group">
            <label>Speed <span class="value"><%= @speed %></span></label>
            <input type="range" min="1" max="100" value={@speed} name="speed" />
          </div>
          <div class="control-group">
            <label>Color</label>
            <input type="color" value={@color} name="color" />
          </div>
        </div>
      </form>

      <div class="controls-row">
        <div class="control-group">
          <label>Wave Type</label>
          <div class="wave-buttons">
            <button
              type="button"
              class={"wave-btn #{if @wave_type == "sine", do: "active"}"}
              phx-click="set_wave_type"
              phx-value-type="sine"
            >
              Sine
            </button>
            <button
              type="button"
              class={"wave-btn #{if @wave_type == "square", do: "active"}"}
              phx-click="set_wave_type"
              phx-value-type="square"
            >
              Square
            </button>
            <button
              type="button"
              class={"wave-btn #{if @wave_type == "sawtooth", do: "active"}"}
              phx-click="set_wave_type"
              phx-value-type="sawtooth"
            >
              Sawtooth
            </button>
          </div>
        </div>
      </div>
    </div>

    <div class="canvas-container">
      <Exclosured.LiveView.sandbox
        module={:visualizer}
        sync={Exclosured.LiveView.sync(assigns, ~w(frequency amplitude speed color wave_type)a)}
        canvas
        width={600}
        height={300}
      />
    </div>

    <p :if={!@wasm_ready} class="status">Loading WASM visualizer...</p>
    <p :if={@wasm_ready} class="status ready">Rendering at 60fps. No push_event calls in this LiveView.</p>

    <div class="how-it-works">
      <h2>How It Works</h2>
      <p>
        The <code>sync</code> attribute on the sandbox component creates a declarative
        binding between LiveView assigns and the WASM module. When any synced value
        changes, the component automatically serializes and pushes the new state.
        This LiveView has zero <code>push_event</code> calls.
      </p>
    </div>
    """
  end

  @impl true
  def handle_event("update_params", params, socket) do
    # Just assign the new values. The sync attribute handles the rest.
    socket =
      socket
      |> maybe_assign_int(params, "frequency", :frequency)
      |> maybe_assign_int(params, "amplitude", :amplitude)
      |> maybe_assign_int(params, "speed", :speed)
      |> maybe_assign_string(params, "color", :color)

    {:noreply, socket}
  end

  def handle_event("set_wave_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, wave_type: type)}
  end

  def handle_event("wasm:ready", %{"module" => "visualizer"}, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:wasm_ready, :visualizer}, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # Helpers

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
end
