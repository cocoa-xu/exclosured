defmodule ConfidentialComputeWeb.PrivacyLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       pw_result: nil,
       pw_score: nil,
       pw_label: nil,
       ssn_result: nil,
       wasm_ready: false,
       server_log: []
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="wasm-loader" phx-hook="ExclosuredHook">
      <div style="margin-bottom: 1rem; text-align: center;">
        <span :if={!@wasm_ready} class="status-badge loading">Loading WASM...</span>
        <span :if={@wasm_ready} class="status-badge ready">WASM Ready</span>
      </div>
    </div>

    <div class="panels">
      <%!-- Password Strength Checker Panel --%>
      <div class="panel">
        <h2>&#128273; Password Strength Checker</h2>

        <label for="pw-input">Enter a password</label>
        <input
          id="pw-input"
          type="password"
          placeholder="Type a password..."
          autocomplete="off"
          phx-hook="WasmPasswordHook"
        />

        <div :if={@pw_label} class="strength-bar-container">
          <div
            class={"strength-bar #{@pw_label}"}
            style={"width: #{strength_percent(@pw_score)}%"}
          >
          </div>
        </div>

        <div :if={@pw_result} style="margin-top: 0.8rem;">
          <div class="result-label browser">Processed in Browser (WASM)</div>
          <div class="result-box">
            Full password analyzed locally. Never leaves your browser.
          </div>
        </div>

        <div :if={@pw_result} style="margin-top: 0.6rem;">
          <div class="result-label server">Server Received</div>
          <div class="result-box server">
            <%= @pw_result %>
          </div>
        </div>

        <%!-- Data flow diagram --%>
        <div class="data-flow">
          <div class="flow-box browser-box">
            <div>Browser WASM</div>
            <div class="flow-detail">Raw input: stays here</div>
          </div>
          <div class="flow-arrow">&#8594;</div>
          <div class="flow-box server-box">
            <div>Server</div>
            <div class="flow-detail">Score + label only</div>
          </div>
        </div>
      </div>

      <%!-- SSN Masker Panel --%>
      <div class="panel">
        <h2>&#128196; SSN Masker</h2>

        <label for="ssn-input">Enter a Social Security Number</label>
        <input
          id="ssn-input"
          type="text"
          placeholder="123-45-6789"
          autocomplete="off"
          phx-hook="WasmSsnHook"
        />

        <div :if={@ssn_result} style="margin-top: 0.8rem;">
          <div class="result-label browser">Processed in Browser (WASM)</div>
          <div class="result-box">
            Full SSN analyzed locally. Never leaves your browser.
          </div>
        </div>

        <div :if={@ssn_result} style="margin-top: 0.6rem;">
          <div class="result-label server">Server Received</div>
          <div class="result-box server">
            <%= @ssn_result %>
          </div>
        </div>

        <%!-- Data flow diagram --%>
        <div class="data-flow">
          <div class="flow-box browser-box">
            <div>Browser WASM</div>
            <div class="flow-detail">Raw input: stays here</div>
          </div>
          <div class="flow-arrow">&#8594;</div>
          <div class="flow-box server-box">
            <div>Server</div>
            <div class="flow-detail">Masked value only</div>
          </div>
        </div>
      </div>
    </div>

    <%!-- Server Event Log --%>
    <div class="server-log">
      <h2>&#128466; What the Server Received</h2>
      <p style="color: #888; font-size: 0.8rem; margin-bottom: 0.8rem;">
        Every event below shows ONLY the computed/masked data, never raw passwords or SSNs.
      </p>
      <div class="log-entries">
        <div :if={@server_log == []} class="empty-log">
          No events received yet. Start typing above.
        </div>
        <div :for={entry <- @server_log} class="log-entry">
          <span class="timestamp"><%= entry.time %></span>
          <span class="event-name"><%= entry.event %></span>
          <span class="event-data"><%= entry.data %></span>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("wasm:ready", _params, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_event("pw_checked", params, socket) do
    score = params["score"] || 0
    label = params["label"] || "weak"
    length = params["length"] || 0

    pw_result = "Score: #{score}/7 (#{label}), #{length} chars"

    log_entry = %{
      time: format_time(),
      event: "pw_checked",
      data: "score=#{score}, label=#{label}, length=#{length}"
    }

    {:noreply,
     assign(socket,
       pw_score: score,
       pw_label: label,
       pw_result: pw_result,
       server_log: [log_entry | socket.assigns.server_log] |> Enum.take(50)
     )}
  end

  def handle_event("ssn_masked", params, socket) do
    valid = params["valid"] || false
    masked = params["masked"] || ""

    ssn_result =
      if valid do
        "Masked: #{masked}"
      else
        masked
      end

    log_entry = %{
      time: format_time(),
      event: "ssn_masked",
      data: "valid=#{valid}, masked=#{masked}"
    }

    {:noreply,
     assign(socket,
       ssn_result: ssn_result,
       server_log: [log_entry | socket.assigns.server_log] |> Enum.take(50)
     )}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp strength_percent(nil), do: 0
  defp strength_percent(score) when is_integer(score), do: round(score / 7 * 100)
  defp strength_percent(_), do: 0

  defp format_time do
    {h, m, s} = :erlang.time()

    h_str = h |> Integer.to_string() |> String.pad_leading(2, "0")
    m_str = m |> Integer.to_string() |> String.pad_leading(2, "0")
    s_str = s |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{h_str}:#{m_str}:#{s_str}"
  end
end
