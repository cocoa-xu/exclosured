defmodule StreamingDemoWeb.PrimeLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       max_n: 100_000,
       primes: [],
       prime_count: 0,
       progress: 0,
       processing: false,
       wasm_ready: false,
       elapsed_ms: 0,
       started_at: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Prime Number Finder</h1>
    <p class="subtitle">
      Streaming results from WASM: each batch of primes arrives via
      <code>exclosured::emit("chunk", ...)</code> and accumulates through
      <code>stream_call</code>'s <code>on_chunk</code> callback.
    </p>

    <Exclosured.LiveView.sandbox module={:prime_sieve} />

    <div class="input-section">
      <form phx-change="update_max" phx-submit="find_primes">
        <div class="input-row">
          <div class="input-group">
            <label>Max number</label>
            <input type="number" name="max_n" value={@max_n} min="10" max="10_000_000" />
          </div>
          <button
            type="submit"
            class="find-btn"
            disabled={@processing || !@wasm_ready}
          >
            <%= if @processing, do: "Scanning...", else: "Find Primes" %>
          </button>
        </div>
      </form>
    </div>

    <div class="progress-section">
      <div class="progress-bar-outer">
        <div class="progress-bar-inner" style={"width: #{@progress}%"}></div>
      </div>
      <div class="stats-row">
        <div class="stat">
          Found <span class="value"><%= @prime_count %></span> primes
        </div>
        <div class="stat">
          Progress <span class="value"><%= @progress %>%</span>
        </div>
        <div :if={@elapsed_ms > 0} class="stat">
          Elapsed <span class="value"><%= @elapsed_ms %> ms</span>
        </div>
      </div>
    </div>

    <div class="results-section">
      <h2>Discovered Primes</h2>
      <div class="primes-container" id="primes-list" phx-update="replace">
        <%= if @primes == [] do %>
          <div class="primes-empty">
            <%= if @wasm_ready do %>
              Click "Find Primes" to start scanning.
            <% else %>
              Loading WASM module...
            <% end %>
          </div>
        <% else %>
          <%= for {prime, idx} <- Enum.with_index(@primes) do %>
            <span id={"p-#{idx}"}><%= prime %><%= if idx < length(@primes) - 1, do: ", " %></span>
          <% end %>
        <% end %>
      </div>
    </div>

    <p :if={!@wasm_ready} class="status">Loading WASM module...</p>
    <p :if={@wasm_ready && !@processing && @prime_count == 0} class="status ready">
      WASM ready. Enter a max number and click "Find Primes".
    </p>
    <p :if={!@processing && @prime_count > 0} class="status ready">
      Done. Found <%= @prime_count %> primes up to <%= @max_n %> in <%= @elapsed_ms %> ms.
    </p>

    <div class="note">
      <p>
        Results stream from WASM via <code>exclosured::emit("chunk", ...)</code> and arrive
        through <code>stream_call</code>'s <code>on_chunk</code> callback. The WASM function
        processes numbers in batches of 1000, emitting each batch of discovered primes as a
        <code>"chunk"</code> event and finishing with a <code>"done"</code> event.
      </p>
    </div>
    """
  end

  @impl true
  def handle_event("update_max", %{"max_n" => max_str}, socket) do
    case Integer.parse(max_str) do
      {n, _} when n > 0 -> {:noreply, assign(socket, max_n: n)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("find_primes", _params, socket) do
    socket =
      socket
      |> assign(
        primes: [],
        prime_count: 0,
        progress: 0,
        processing: true,
        elapsed_ms: 0,
        started_at: System.monotonic_time(:millisecond)
      )
      |> Exclosured.LiveView.stream_call(:prime_sieve, "find_primes", [socket.assigns.max_n],
        on_chunk: fn chunk, sock ->
          new_primes = chunk["primes"] || []

          sock
          |> update(:primes, &(&1 ++ new_primes))
          |> update(:prime_count, &(&1 + length(new_primes)))
          |> assign(progress: chunk["progress"] || 0)
        end,
        on_done: fn sock ->
          elapsed = System.monotonic_time(:millisecond) - (sock.assigns.started_at || 0)
          assign(sock, processing: false, progress: 100, elapsed_ms: elapsed)
        end
      )

    {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:wasm_ready, :prime_sieve}, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
