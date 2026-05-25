defmodule StreamingDemoWeb.WorkerLive do
  use Phoenix.LiveView

  @default_iterations 180_000_000
  @timeout_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       iterations: @default_iterations,
       main_ready: false,
       worker_ready: false,
       main_running: false,
       worker_running: false,
       main_progress: 0,
       worker_progress: 0,
       main_elapsed_ms: nil,
       worker_elapsed_ms: nil,
       main_checksum: nil,
       worker_checksum: nil,
       main_ref: nil,
       worker_ref: nil,
       main_started_at: nil,
       worker_started_at: nil,
       main_error: nil,
       worker_error: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="demo-nav">
      <a href="/">Streaming primes</a>
      <span>Worker comparison</span>
    </nav>

    <h1>Worker Mode Comparison</h1>
    <p class="subtitle">
      Run the same CPU-heavy WASM loop on the browser main thread and in a Web Worker.
      Watch the frame meter while each run is active: main-thread work freezes rendering,
      while worker mode keeps the page responsive.
    </p>

    <div class="wasm-sandboxes" aria-hidden="true">
      <Exclosured.LiveView.sandbox module={:cpu_main} />
      <Exclosured.LiveView.sandbox module={:cpu_worker} worker />
    </div>

    <div class="frame-section">
      <div id="frame-pulse" phx-hook="FramePulse" phx-update="ignore" class="frame-meter">
        <div class="frame-track">
          <span data-dot class="frame-dot"></span>
        </div>
        <strong data-fps>measuring...</strong>
      </div>
    </div>

    <form phx-change="update_iterations" class="input-section">
      <div class="input-row">
        <div class="input-group">
          <label>Iterations</label>
          <input
            type="number"
            name="iterations"
            value={@iterations}
            min="1000000"
            max="1000000000"
            step="1000000"
          />
        </div>
        <button
          type="button"
          class="find-btn"
          phx-click="run_main"
          disabled={!@main_ready || @main_running}
        >
          Run Main Thread
        </button>
        <button
          type="button"
          class="find-btn secondary"
          phx-click="run_worker"
          disabled={!@worker_ready || @worker_running}
        >
          Run Worker
        </button>
      </div>
    </form>

    <div class="compare-grid">
      <.run_panel
        title="Main Thread"
        ready={@main_ready}
        running={@main_running}
        progress={@main_progress}
        elapsed_ms={@main_elapsed_ms}
        checksum={@main_checksum}
        error={@main_error}
      />
      <.run_panel
        title="Web Worker"
        ready={@worker_ready}
        running={@worker_running}
        progress={@worker_progress}
        elapsed_ms={@worker_elapsed_ms}
        checksum={@worker_checksum}
        error={@worker_error}
      />
    </div>

    <div class="note">
      <p>
        Both buttons call equivalent Rust code through <code>Exclosured.LiveView.call_async/5</code>.
        The worker sandbox adds <code>data-wasm-worker="true"</code>, so the hook executes the
        module in a dedicated Worker and forwards the same <code>wasm:result</code> and
        <code>wasm:emit</code> messages back to LiveView.
      </p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:ready, :boolean, required: true)
  attr(:running, :boolean, required: true)
  attr(:progress, :integer, required: true)
  attr(:elapsed_ms, :integer, default: nil)
  attr(:checksum, :integer, default: nil)
  attr(:error, :any, default: nil)

  def run_panel(assigns) do
    ~H"""
    <section class="compare-panel">
      <h2><%= @title %></h2>
      <p class={["panel-status", status_class(@ready, @running, @error)]}>
        <%= panel_status(@ready, @running, @error) %>
      </p>
      <div class="progress-bar-outer">
        <div class="progress-bar-inner" style={"width: #{@progress}%"}></div>
      </div>
      <div class="stats-row">
        <div class="stat">
          Progress <span class="value"><%= @progress %>%</span>
        </div>
        <div :if={not is_nil(@elapsed_ms)} class="stat">
          Elapsed <span class="value"><%= @elapsed_ms %> ms</span>
        </div>
        <div :if={not is_nil(@checksum)} class="stat">
          Checksum <span class="value"><%= @checksum %></span>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("update_iterations", %{"iterations" => value}, socket) do
    iterations =
      case Integer.parse(value) do
        {n, _rest} -> n |> max(1_000_000) |> min(1_000_000_000)
        :error -> socket.assigns.iterations
      end

    {:noreply, assign(socket, iterations: iterations)}
  end

  def handle_event("run_main", _params, socket) do
    {:noreply, start_run(socket, :main, :cpu_main)}
  end

  def handle_event("run_worker", _params, socket) do
    {:noreply, start_run(socket, :worker, :cpu_worker)}
  end

  def handle_event("wasm:ready", %{"module" => "cpu_main"}, socket) do
    {:noreply, assign(socket, main_ready: true)}
  end

  def handle_event("wasm:ready", %{"module" => "cpu_worker"}, socket) do
    {:noreply, assign(socket, worker_ready: true)}
  end

  def handle_event("wasm:error", %{"module" => module, "error" => error}, socket) do
    {:noreply, assign_module_error(socket, String.to_existing_atom(module), error)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:wasm_emit, module, "progress", %{"percent" => percent}}, socket) do
    {:noreply, assign_progress(socket, module, percent)}
  end

  def handle_info({:wasm_result, ref, module, "burn", checksum}, socket) do
    {:noreply, finish_run(socket, ref, module, checksum)}
  end

  def handle_info({:wasm_error, ref, module, "burn", reason}, socket) do
    {:noreply, fail_run(socket, ref, module, reason)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp start_run(socket, mode, module) do
    started_at = System.monotonic_time(:millisecond)

    {:ok, ref, socket} =
      Exclosured.LiveView.call_async(socket, module, "burn", [socket.assigns.iterations],
        timeout: @timeout_ms
      )

    socket
    |> assign(:"#{mode}_running", true)
    |> assign(:"#{mode}_progress", 0)
    |> assign(:"#{mode}_elapsed_ms", nil)
    |> assign(:"#{mode}_checksum", nil)
    |> assign(:"#{mode}_error", nil)
    |> assign(:"#{mode}_ref", ref)
    |> assign(:"#{mode}_started_at", started_at)
  end

  defp assign_progress(socket, :cpu_main, percent), do: assign(socket, main_progress: percent)
  defp assign_progress(socket, :cpu_worker, percent), do: assign(socket, worker_progress: percent)
  defp assign_progress(socket, _module, _percent), do: socket

  defp finish_run(socket, ref, module, checksum) do
    mode = mode_for(module)

    if mode && ref == socket.assigns[:"#{mode}_ref"] do
      elapsed_ms = System.monotonic_time(:millisecond) - socket.assigns[:"#{mode}_started_at"]

      socket
      |> assign(:"#{mode}_running", false)
      |> assign(:"#{mode}_progress", 100)
      |> assign(:"#{mode}_elapsed_ms", elapsed_ms)
      |> assign(:"#{mode}_checksum", checksum)
      |> assign(:"#{mode}_ref", nil)
      |> assign(:"#{mode}_started_at", nil)
    else
      socket
    end
  end

  defp fail_run(socket, ref, module, reason) do
    mode = mode_for(module)

    if mode && ref == socket.assigns[:"#{mode}_ref"] do
      socket
      |> assign(:"#{mode}_running", false)
      |> assign(:"#{mode}_error", inspect(reason))
      |> assign(:"#{mode}_ref", nil)
      |> assign(:"#{mode}_started_at", nil)
    else
      socket
    end
  end

  defp assign_module_error(socket, :cpu_main, error), do: assign(socket, main_error: error)
  defp assign_module_error(socket, :cpu_worker, error), do: assign(socket, worker_error: error)
  defp assign_module_error(socket, _module, _error), do: socket

  defp mode_for(:cpu_main), do: :main
  defp mode_for(:cpu_worker), do: :worker
  defp mode_for(_module), do: nil

  defp panel_status(_ready, _running, error) when not is_nil(error), do: "Error: #{error}"
  defp panel_status(_ready, true, _error), do: "Running"
  defp panel_status(true, false, _error), do: "Ready"
  defp panel_status(false, false, _error), do: "Loading WASM"

  defp status_class(_ready, _running, error) when not is_nil(error), do: "error"
  defp status_class(_ready, true, _error), do: "running"
  defp status_class(true, false, _error), do: "ready"
  defp status_class(false, false, _error), do: "loading"
end
