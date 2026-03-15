defmodule WasmAiWeb.InferenceLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       input: "",
       result: nil,
       progress: 0,
       processing: false,
       wasm_ready: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>WASM AI Text Processor</h1>
    <p class="desc">
      Demonstrates compute-mode WASM: text is sent to a Rust WASM module
      running in your browser, processed locally, and results are sent
      back to the LiveView server.
    </p>

    <div id="wasm-text-engine" phx-hook="Exclosured" data-wasm-module="text_engine">
    </div>

    <form phx-submit="process">
      <textarea
        name="input"
        placeholder="Enter text to process in WASM..."
        phx-change="update_input"
        value={@input}
      ><%= @input %></textarea>

      <button type="submit" disabled={@processing || !@wasm_ready}>
        <%= if @processing, do: "Processing...", else: "Process in WASM" %>
      </button>
    </form>

    <div :if={@processing} class="progress">
      <div class="progress-bar" style={"width: #{@progress}%"}></div>
    </div>
    <p :if={@processing} class="status">Processing... <%= @progress %>%</p>

    <div :if={@result} class="result">
      <h3>Result from WASM</h3>
      <pre><%= @result %></pre>
    </div>

    <p :if={!@wasm_ready} class="status">Loading WASM module...</p>
    """
  end

  @impl true
  def handle_event("update_input", %{"input" => input}, socket) do
    {:noreply, assign(socket, input: input)}
  end

  def handle_event("process", %{"input" => input}, socket) do
    socket =
      socket
      |> assign(processing: true, progress: 0, result: nil, input: input)
      |> Exclosured.LiveView.call(:text_engine, "process", [input])

    {:noreply, socket}
  end

  # WASM module loaded and ready
  def handle_event("wasm:ready", %{"module" => "text_engine"}, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  # WASM function returned a result
  def handle_event("wasm:result", %{"func" => "process", "result" => result}, socket) do
    {:noreply, assign(socket, result: inspect(result), processing: false, progress: 100)}
  end

  # WASM emitted a progress event
  def handle_event("wasm:emit", %{"event" => "progress", "payload" => payload}, socket) do
    {:noreply, assign(socket, progress: payload["percent"] || 0)}
  end

  # WASM error
  def handle_event("wasm:error", %{"error" => error}, socket) do
    {:noreply, assign(socket, result: "Error: #{error}", processing: false)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:wasm_result, :text_engine, "process", result}, socket) do
    {:noreply, assign(socket, result: inspect(result), processing: false, progress: 100)}
  end

  def handle_info({:wasm_emit, :text_engine, "progress", payload}, socket) do
    {:noreply, assign(socket, progress: payload["percent"] || 0)}
  end

  def handle_info({:wasm_error, :text_engine, _func, error}, socket) do
    {:noreply, assign(socket, result: "Error: #{error}", processing: false)}
  end

  def handle_info({:wasm_ready, :text_engine}, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
