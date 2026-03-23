defmodule PrivateAnalyticsWeb.RoomLive do
  use Phoenix.LiveView, layout: {PrivateAnalyticsWeb.Layouts, :app}

  alias PrivateAnalytics.Room

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PrivateAnalytics.PubSub, "room:#{room_id}")
    end

    socket =
      assign(socket,
        room_id: room_id,
        role: :pending,
        sql: "SELECT * FROM data LIMIT 50",
        wasm_ready: false,
        schema: nil,
        rows: nil,
        page: 1,
        total_pages: 0,
        total_rows: 0,
        error: nil,
        viewer_count: 0,
        theme: "dark",
        share_open: false,
        room_closed: false,
        display_name: "Anonymous"
      )

    {:ok, socket}
  end

  ## Event handlers from the client

  @impl true
  def handle_event("wasm_ready", _params, socket) do
    socket = assign(socket, wasm_ready: true)
    {:noreply, push_event(socket, "init_state", %{room_id: socket.assigns.room_id})}
  end

  @impl true
  def handle_event("join_room", %{"token_hash" => token_hash}, socket) do
    room_id = socket.assigns.room_id

    case Room.join(room_id, self(), token_hash) do
      {:ok, role} ->
        socket = assign(socket, role: role)

        # If joining as viewer/editor, send existing schema + results
        if role in [:viewer, :editor] do
          case Room.get_state(room_id) do
            {:ok, state} ->
              socket = assign(socket, viewer_count: state.viewer_count)

              # Push current schema if available
              socket =
                if state.current_schema do
                  push_event(socket, "render_schema", %{schema: state.current_schema})
                else
                  socket
                end

              # Push current view (results) if available
              socket =
                if state.current_view do
                  push_event(socket, "render_view", %{data: state.current_view})
                else
                  socket
                end

              {:noreply, socket}

            _ ->
              {:noreply, socket}
          end
        else
          {:noreply, socket}
        end

      {:error, :room_not_found} ->
        {:noreply, assign(socket, error: "Room not found. You may need to create it first.")}

      {:error, :invalid_token} ->
        {:noreply, assign(socket, error: "Invalid access token.")}
    end
  end

  @impl true
  def handle_event("create_room", %{"viewer_hash" => vh, "editor_hash" => eh}, socket) do
    room_id = socket.assigns.room_id

    case Room.create(room_id, self(), vh, eh) do
      {:ok, _pid} ->
        {:noreply, assign(socket, role: :owner)}

      {:error, {:already_started, _pid}} ->
        # Room already exists; try to join as owner
        case Room.join(room_id, self(), "") do
          {:ok, role} -> {:noreply, assign(socket, role: role)}
          _ -> {:noreply, assign(socket, error: "Room already exists.")}
        end
    end
  end

  @impl true
  def handle_event("submit_query", %{"sql" => sql}, socket) do
    socket = assign(socket, sql: sql, error: nil)

    case socket.assigns.role do
      :owner ->
        # Owner executes directly in their browser
        {:noreply, push_event(socket, "execute_query", %{sql: sql})}

      :editor ->
        # Editor relays encrypted SQL to owner
        Room.submit_query(socket.assigns.room_id, self(), sql)
        {:noreply, socket}

      _ ->
        {:noreply, assign(socket, error: "You do not have permission to run queries.")}
    end
  end

  @impl true
  def handle_event("update_sql", %{"value" => sql}, socket) do
    # Broadcast SQL changes to all other users for live sync
    if socket.assigns.role in [:owner, :editor] do
      Room.broadcast_sql(socket.assigns.room_id, self(), sql)
    end

    {:noreply, assign(socket, sql: sql)}
  end

  @impl true
  def handle_event("query_result", %{"data" => data} = params, socket) do
    if socket.assigns.role == :owner do
      Room.broadcast_view(socket.assigns.room_id, data)

      total_rows = params["total_rows"] || 0
      socket = assign(socket, total_rows: total_rows)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("schema_update", %{"encrypted_schema" => schema}, socket) do
    if socket.assigns.role == :owner do
      Room.broadcast_schema(socket.assigns.room_id, schema)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("page_change", %{"page" => page}, socket) do
    page = if is_binary(page), do: String.to_integer(page), else: page

    case socket.assigns.role do
      :owner ->
        {:noreply, push_event(socket, "change_page", %{page: page})}

      _ ->
        # Relay page request to owner
        Room.submit_query(
          socket.assigns.room_id,
          self(),
          Jason.encode!(%{type: "page_change", page: page})
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_theme", _params, socket) do
    new_theme = if socket.assigns.theme == "dark", do: "light", else: "dark"
    {:noreply, push_event(assign(socket, theme: new_theme), "set_theme", %{theme: new_theme})}
  end

  @impl true
  def handle_event("toggle_share", _params, socket) do
    {:noreply, assign(socket, share_open: !socket.assigns.share_open)}
  end

  @impl true
  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, error: nil)}
  end

  @impl true
  def handle_event("cursor_hover", params, socket) do
    Room.update_cursor(socket.assigns.room_id, self(), params)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_display_name", %{"name" => name}, socket) do
    name = String.slice(name, 0..20)
    Room.set_display_name(socket.assigns.room_id, self(), name)
    {:noreply, assign(socket, display_name: name)}
  end

  @impl true
  def handle_event("pii_columns_changed", %{"columns" => cols}, socket) do
    if socket.assigns.role == :owner do
      # Broadcast the masked column list to all viewers so they know to re-fetch
      Room.broadcast_pii_config(socket.assigns.room_id, cols)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("query_error", %{"error" => error_msg}, socket) do
    {:noreply, assign(socket, error: error_msg)}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  ## Incoming messages from Room GenServer and PubSub

  @impl true
  def handle_info({:query_request, encrypted_sql, from_pid}, socket) do
    if socket.assigns.role == :owner do
      {:noreply,
       push_event(socket, "execute_remote_query", %{
         sql: encrypted_sql,
         from: inspect(from_pid)
       })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:view_update, encrypted_data}, socket) do
    {:noreply, push_event(socket, "render_view", %{data: encrypted_data})}
  end

  @impl true
  def handle_info({:cursor_update, cursors}, socket) do
    {:noreply, push_event(socket, "cursor_update", %{cursors: cursors})}
  end

  @impl true
  def handle_info({:sql_sync, sql}, socket) do
    socket =
      socket
      |> assign(sql: sql)
      |> push_event("sync_sql", %{sql: sql})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pii_config_changed, columns}, socket) do
    # Owner changed PII columns, re-broadcast current view with new masking
    # This triggers the owner to re-send masked data to viewers
    {:noreply, push_event(socket, "pii_config_update", %{masked_columns: columns})}
  end

  @impl true
  def handle_info({:schema_update, encrypted_schema}, socket) do
    {:noreply, push_event(socket, "render_schema", %{schema: encrypted_schema})}
  end

  @impl true
  def handle_info({:viewer_count_update, count}, socket) do
    {:noreply, assign(socket, viewer_count: count)}
  end

  @impl true
  def handle_info({:pagination_update, page, total_pages, total_rows}, socket) do
    {:noreply, assign(socket, page: page, total_pages: total_pages, total_rows: total_rows)}
  end

  @impl true
  def handle_info({:room_closed}, socket) do
    {:noreply, assign(socket, room_closed: true, error: "The room owner has disconnected.")}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div id="room-container" phx-hook="RoomHook" data-room-id={@room_id} data-role={@role}>
      <%!-- Room header --%>
      <div class="room-header">
        <div class="room-header-left">
          <span class="lock-icon">&#128274;</span>
          <span class="room-name">Private Analytics</span>
          <span class="room-id-label"><%= @room_id %></span>
          <span :if={@role != :pending} class={"role-badge #{@role}"}><%= @role %></span>
        </div>
        <div class="room-header-right">
          <div :if={@role != :pending} class="name-input-container" id="name-container" phx-update="ignore">
            <input
              type="text"
              id="display-name-input"
              class="name-input"
              value={@display_name}
              placeholder="Your name"
              maxlength="20"
            />
          </div>
          <span class="viewer-count">
            &#128101; <%= @viewer_count %> viewer<%= if @viewer_count != 1, do: "s" %>
          </span>
          <div :if={@role == :owner} class="share-popover-container">
            <button class="header-btn" phx-click="toggle_share" title="Share room">
              &#128279; Share
            </button>
            <div :if={@share_open} class="share-popover" id="share-panel" phx-update="ignore">
              <div class="share-popover-title">Share this room</div>
              <div class="share-row">
                <label>View only</label>
                <div class="share-input-row">
                  <input type="text" id="share-view-url" readonly class="share-url-input" />
                  <button class="copy-btn" id="copy-view-url" title="Copy">&#128203;</button>
                </div>
              </div>
              <div class="share-row">
                <label>Can edit</label>
                <div class="share-input-row">
                  <input type="text" id="share-edit-url" readonly class="share-url-input" />
                  <button class="copy-btn" id="copy-edit-url" title="Copy">&#128203;</button>
                </div>
              </div>
            </div>
          </div>
          <button class="header-btn" phx-click="toggle_theme" title="Toggle theme">
            <%= if @theme == "dark", do: Phoenix.HTML.raw("&#9728;"), else: Phoenix.HTML.raw("&#9790;") %>
          </button>
        </div>
      </div>

      <%!-- Error display --%>
      <div :if={@error} class="error-bar">
        <%= @error %>
        <button class="btn btn-sm btn-secondary" style="margin-left: 0.5rem;" phx-click="clear_error">
          Dismiss
        </button>
      </div>

      <%!-- Room closed warning --%>
      <div :if={@room_closed && @role != :owner} class="card">
        <div class="waiting-message">
          <p>The room owner has disconnected. The room will close shortly.</p>
        </div>
      </div>

      <%!-- Owner: data loading area --%>
      <div :if={@role == :owner} id="upload-section" phx-update="ignore">
        <div id="data-load-area" class="card">
          <div class="card-title">Load Data</div>
          <div class="load-tabs">
            <button class="load-tab active" data-tab="file" onclick="switchLoadTab('file')">Upload File</button>
            <button class="load-tab" data-tab="url" onclick="switchLoadTab('url')">Load from URL</button>
          </div>
          <div id="tab-file" class="load-tab-content active">
            <div class="upload-area" id="drop-zone">
              <div class="upload-icon">&#128196;</div>
              <p>Drop a CSV or Parquet file here, or click to browse</p>
              <input type="file" id="csv-file-input" accept=".csv,.tsv,.parquet" style="display:none;" />
            </div>
          </div>
          <div id="tab-url" class="load-tab-content" style="display:none;">
            <div class="url-load-area">
              <p class="url-hint">
                Paste a URL to a Parquet or CSV file. DuckDB fetches it directly in your browser.
              </p>
              <div class="url-input-row">
                <input type="text" id="data-url-input" class="url-input"
                       placeholder="https://huggingface.co/datasets/.../0000.parquet" />
                <button class="btn btn-primary" id="btn-load-url" onclick="loadFromUrl()">Load</button>
              </div>
              <p class="url-examples">
                The remote host must allow cross-origin requests (CORS).
                Hugging Face and GitHub raw URLs work. For other sources, use the file upload tab.
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Schema section (above query, collapsible) --%>
      <div :if={@role != :pending} class="card" id="schema-section">
        <div class="card-title card-title-collapsible" id="schema-toggle" onclick="toggleSchema()">
          <span>Schema</span>
          <span class="collapse-icon" id="schema-collapse-icon">&#9660;</span>
        </div>
        <div id="schema-container" class="schema-collapsible" phx-update="ignore">
          <div class="schema-list" id="schema-list">
            <span style="color: var(--text-dim); font-size: 0.85rem;">
              No schema loaded yet.
            </span>
          </div>
        </div>
      </div>

      <%!-- SQL editor section --%>
      <div :if={@role in [:owner, :editor]} class="card">
        <div class="card-title">SQL Query</div>
        <div class="sql-editor-area" id="sql-editor-wrapper" phx-update="ignore">
          <div id="sql-display" class="sql-display"></div>
          <textarea
            id="sql-editor"
            spellcheck="false"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="off"
          ><%= @sql %></textarea>
        </div>
        <div class="query-bar">
          <span class="query-status" id="query-status"></span>
          <span :if={@role == :owner} id="pii-indicator" class="pii-indicator" style="display:none;"></span>
          <button
            class="btn btn-primary"
            phx-click="submit_query"
            phx-value-sql={@sql}
            disabled={not @wasm_ready and @role == :owner}
          >
            Run Query
          </button>
        </div>

        <%!-- PII Masking subsection (collapsible, inside the query card) --%>
        <div :if={@role == :owner} id="pii-section" class="pii-subsection">
          <div class="pii-subsection-header" id="pii-subsection-toggle" onclick="togglePiiSection()">
            <span>PII Masking</span>
            <span class="collapse-icon" id="pii-collapse-icon">&#9654;</span>
          </div>
          <div id="pii-config" class="pii-subsection-body collapsed" phx-update="ignore">
            <p class="pii-description">
              Select columns to mask. Changes apply immediately to your view and all viewers.
            </p>
            <div class="pii-actions">
              <button class="btn btn-sm" id="pii-auto-detect">Auto-detect</button>
              <button class="btn btn-sm" id="pii-select-all">Select all</button>
              <button class="btn btn-sm" id="pii-select-none">Clear all</button>
            </div>
            <div class="pii-columns" id="pii-column-list">
              <span class="pii-empty">Load data and run a query first.</span>
            </div>
            <div class="pii-self-mask">
              <label class="pii-toggle">
                <input type="checkbox" id="pii-mask-self" checked /> Also mask in my own view
              </label>
            </div>
          </div>
        </div>
      </div>

      <%!-- Viewer: read-only SQL display --%>
      <div :if={@role == :viewer} class="card">
        <div class="card-title">Query (read only)</div>
        <div class="sql-editor-area" id="sql-viewer-wrapper" phx-update="ignore">
          <div id="sql-viewer-display" class="sql-display" style="position:static; pointer-events:auto;"></div>
        </div>
      </div>

      <%!-- Results section --%>
      <div :if={@role != :pending} class="card" id="results-section">
        <div class="card-title">Results</div>
        <div id="results-container" phx-update="ignore">
          <div class="results-wrapper" id="results-wrapper">
            <div class="results-empty" id="results-empty">
              No results yet. Run a query to see data here.
            </div>
            <table class="results-table" id="results-table" style="display:none;"></table>
          </div>
        </div>
      </div>

      <%!-- Pagination is handled client-side (each user paginates independently) --%>

      <%!-- Pending state: waiting to join --%>
      <div :if={@role == :pending && !@error} class="card">
        <div class="waiting-message">
          <div class="spinner"></div>
          <p>Connecting to room...</p>
        </div>
      </div>
    </div>
    """
  end
end
