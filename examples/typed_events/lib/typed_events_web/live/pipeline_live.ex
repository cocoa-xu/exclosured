defmodule TypedEventsWeb.PipelineLive do
  use Phoenix.LiveView

  alias TypedEventsWeb.Events

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       status: :idle,
       item_count: 20,
       stages: [],
       completed_stage_names: [],
       current_stage: nil,
       items_processed: 0,
       total_items: 0,
       total_stages: 0,
       success_rate: 0.0,
       total_duration_ms: 0,
       event_log: [],
       wasm_ready: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Data Pipeline Monitor</h1>
    <p class="subtitle">
      Typed events from WASM: Rust structs become Elixir structs via
      <code>use Exclosured.Events</code>. Pattern match on struct fields
      instead of digging through raw maps.
    </p>

    <Exclosured.LiveView.sandbox module={:pipeline} />

    <div class="controls">
      <form phx-change="update_count" phx-submit="run_pipeline">
        <div style="display: flex; gap: 1rem; align-items: flex-end;">
          <div class="item-count-group">
            <label>Items to process</label>
            <input type="number" name="count" value={@item_count} min="1" max="1000" />
          </div>
          <button
            type="submit"
            class="run-btn"
            disabled={@status == :running || !@wasm_ready}
          >
            <%= if @status == :running, do: "Running...", else: "Run Pipeline" %>
          </button>
        </div>
      </form>
    </div>

    <div class="pipeline-status">
      <h2>Pipeline Status</h2>
      <span class={"status-badge #{@status}"}><%= status_label(@status) %></span>
    </div>

    <div class="dashboard">
      <div class="stat-card">
        <div class="label">Items Processed</div>
        <div class="value"><%= @items_processed %> / <%= @total_items %></div>
      </div>
      <div class="stat-card">
        <div class="label">Stages Completed</div>
        <div class="value"><%= length(@stages) %> / <%= @total_stages %></div>
      </div>
      <div class="stat-card">
        <div class="label">Success Rate</div>
        <div class={"value #{success_class(@success_rate)}"}>
          <%= Float.round(@success_rate * 100, 1) %>%
        </div>
      </div>
      <div class="stat-card">
        <div class="label">Total Duration</div>
        <div class="value"><%= @total_duration_ms %> ms</div>
      </div>
    </div>

    <div class="stages-section">
      <h2>Processing Stages</h2>
      <div class="stages-grid">
        <div class={"stage-card #{stage_status("parse", @completed_stage_names, @current_stage)}"}>
          <div class="stage-name">Parse</div>
          <div class="stage-items"><%= stage_items("parse", @stages) %></div>
          <div class="stage-duration"><%= stage_duration("parse", @stages) %></div>
        </div>
        <div class={"stage-card #{stage_status("validate", @completed_stage_names, @current_stage)}"}>
          <div class="stage-name">Validate</div>
          <div class="stage-items"><%= stage_items("validate", @stages) %></div>
          <div class="stage-duration"><%= stage_duration("validate", @stages) %></div>
        </div>
        <div class={"stage-card #{stage_status("transform", @completed_stage_names, @current_stage)}"}>
          <div class="stage-name">Transform</div>
          <div class="stage-items"><%= stage_items("transform", @stages) %></div>
          <div class="stage-duration"><%= stage_duration("transform", @stages) %></div>
        </div>
      </div>
    </div>

    <div class="event-log">
      <h2>Event Log (Typed Structs)</h2>
      <div class="log-entries" id="event-log" phx-update="replace">
        <%= if @event_log == [] do %>
          <div class="log-empty">
            <%= if @wasm_ready do %>
              No events yet. Click "Run Pipeline" to start.
            <% else %>
              Loading WASM module...
            <% end %>
          </div>
        <% else %>
          <%= for {entry, idx} <- Enum.with_index(Enum.reverse(@event_log)) do %>
            <div class="log-entry" id={"log-#{idx}"}>
              <span class={"event-type #{entry.css_class}"}><%= entry.type %></span>
              <span class="event-data"><%= entry.data %></span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <p :if={!@wasm_ready} class="status-text">Loading WASM module...</p>
    <p :if={@wasm_ready && @status == :idle} class="status-text ready">
      WASM ready. Configure item count and click "Run Pipeline".
    </p>
    <p :if={@status == :finished} class="status-text ready">
      Pipeline complete. Processed <%= @items_processed %> items in <%= @total_duration_ms %> ms.
    </p>

    <div class="how-it-works">
      <h2>How Typed Events Work</h2>
      <p>
        Annotate Rust structs with <code>/// exclosured:event</code> and
        <code>use Exclosured.Events</code> generates matching Elixir structs
        at compile time. Each struct gets <code>from_payload/1</code> to convert
        JSON maps into proper structs with typed fields.
      </p>

      <p>
        <strong>Before:</strong> raw maps with string keys, no compile-time checking.
        <strong>After:</strong> proper structs with typed fields and <code>from_payload/1</code>.
        See the README for code examples.
      </p>
    </div>
    """
  end

  @impl true
  def handle_event("update_count", %{"count" => count_str}, socket) do
    case Integer.parse(count_str) do
      {n, _} when n > 0 -> {:noreply, assign(socket, item_count: n)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("run_pipeline", _params, socket) do
    socket =
      socket
      |> assign(
        status: :running,
        stages: [],
        completed_stage_names: [],
        current_stage: nil,
        items_processed: 0,
        total_items: 0,
        total_stages: 0,
        success_rate: 0.0,
        total_duration_ms: 0,
        event_log: []
      )
      |> Exclosured.LiveView.call(:pipeline, "run_pipeline", [socket.assigns.item_count])

    {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:wasm_emit, :pipeline, "pipeline_started", payload}, socket) do
    event = Events.PipelineStarted.from_payload(payload)

    log_entry = %{
      type: "PipelineStarted",
      css_class: "pipeline-started",
      data: "total_items=#{event.total_items}, stages=#{event.stages}"
    }

    socket =
      socket
      |> assign(
        total_items: event.total_items,
        total_stages: event.stages,
        status: :running
      )
      |> update(:event_log, &[log_entry | &1])

    {:noreply, socket}
  end

  def handle_info({:wasm_emit, :pipeline, "stage_complete", payload}, socket) do
    event = Events.StageComplete.from_payload(payload)

    log_entry = %{
      type: "StageComplete",
      css_class: "stage-complete",
      data: "stage=#{event.stage_name}, items=#{event.items_processed}, duration=#{event.duration_ms}ms"
    }

    socket =
      socket
      |> update(:stages, &[event | &1])
      |> update(:completed_stage_names, &[event.stage_name | &1])
      |> assign(current_stage: nil)
      |> update(:event_log, &[log_entry | &1])

    {:noreply, socket}
  end

  def handle_info({:wasm_emit, :pipeline, "item_processed", payload}, socket) do
    event = Events.ItemProcessed.from_payload(payload)

    log_entry = %{
      type: "ItemProcessed",
      css_class: "item-processed",
      data: "item_id=#{event.item_id}, stage=#{event.stage_name}, result=#{event.result}"
    }

    socket =
      socket
      |> update(:items_processed, &(&1 + 1))
      |> assign(current_stage: event.stage_name)
      |> update(:event_log, &[log_entry | &1])

    {:noreply, socket}
  end

  def handle_info({:wasm_emit, :pipeline, "pipeline_finished", payload}, socket) do
    event = Events.PipelineFinished.from_payload(payload)

    log_entry = %{
      type: "PipelineFinished",
      css_class: "pipeline-finished",
      data: "processed=#{event.total_processed}, duration=#{event.total_duration_ms}ms, success=#{Float.round(event.success_rate * 100, 1)}%"
    }

    socket =
      socket
      |> assign(
        status: :finished,
        total_duration_ms: event.total_duration_ms,
        success_rate: event.success_rate,
        items_processed: event.total_processed,
        current_stage: nil
      )
      |> update(:event_log, &[log_entry | &1])

    {:noreply, socket}
  end

  def handle_info({:wasm_ready, :pipeline}, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # Helper functions

  defp status_label(:idle), do: "Idle"
  defp status_label(:running), do: "Running"
  defp status_label(:finished), do: "Finished"

  defp success_class(rate) when rate >= 0.9, do: "success"
  defp success_class(rate) when rate >= 0.7, do: "warning"
  defp success_class(_rate), do: ""

  defp stage_status(name, completed, current) do
    cond do
      name in completed -> "complete"
      name == current -> "active"
      true -> "pending"
    end
  end

  defp stage_items(name, stages) do
    case Enum.find(stages, &(&1.stage_name == name)) do
      nil -> "Waiting..."
      stage -> "#{stage.items_processed} items"
    end
  end

  defp stage_duration(name, stages) do
    case Enum.find(stages, &(&1.stage_name == name)) do
      nil -> ""
      stage -> "#{stage.duration_ms} ms"
    end
  end
end
