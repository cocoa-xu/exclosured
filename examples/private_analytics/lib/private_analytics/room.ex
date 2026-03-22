defmodule PrivateAnalytics.Room do
  @moduledoc """
  GenServer managing a single private analytics room.

  The room stores encrypted views and schemas, relays encrypted queries
  between editors and the owner, and handles rate limiting for broadcasts.
  The server never sees plaintext data; it only relays opaque encrypted blobs.
  """

  use GenServer

  @owner_grace_period_ms 30_000
  @default_max_broadcasts 10

  ## Public API

  def create(room_id, owner_pid, viewer_token_hash, editor_token_hash) do
    spec = {__MODULE__, {room_id, owner_pid, viewer_token_hash, editor_token_hash}}

    DynamicSupervisor.start_child(PrivateAnalytics.RoomSupervisor, spec)
  end

  def join(room_id, pid, token_hash) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.call(room_pid, {:join, pid, token_hash})
      :error -> {:error, :room_not_found}
    end
  end

  def leave(room_id, pid) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:leave, pid})
      :error -> :ok
    end
  end

  def submit_query(room_id, from_pid, encrypted_sql) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:submit_query, from_pid, encrypted_sql})
      :error -> {:error, :room_not_found}
    end
  end

  def broadcast_view(room_id, encrypted_data) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:broadcast_view, encrypted_data})
      :error -> {:error, :room_not_found}
    end
  end

  def broadcast_schema(room_id, encrypted_schema) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:broadcast_schema, encrypted_schema})
      :error -> {:error, :room_not_found}
    end
  end

  def update_cursor(room_id, from_pid, cursor_info) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:update_cursor, from_pid, cursor_info})
      :error -> :ok
    end
  end

  def set_display_name(room_id, pid, name) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:set_name, pid, name})
      :error -> :ok
    end
  end

  def broadcast_sql(room_id, from_pid, sql) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:broadcast_sql, from_pid, sql})
      :error -> :ok
    end
  end

  def broadcast_pii_config(room_id, columns) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.cast(room_pid, {:broadcast_pii_config, columns})
      :error -> :ok
    end
  end

  def update_pagination(room_id, page, total_pages, total_rows) do
    case lookup(room_id) do
      {:ok, room_pid} ->
        GenServer.cast(room_pid, {:update_pagination, page, total_pages, total_rows})

      :error ->
        {:error, :room_not_found}
    end
  end

  def get_state(room_id) do
    case lookup(room_id) do
      {:ok, room_pid} -> GenServer.call(room_pid, :get_state)
      :error -> {:error, :room_not_found}
    end
  end

  ## Child spec and start_link

  def child_spec({room_id, owner_pid, viewer_token_hash, editor_token_hash}) do
    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [{room_id, owner_pid, viewer_token_hash, editor_token_hash}]},
      restart: :temporary
    }
  end

  def start_link({room_id, owner_pid, viewer_token_hash, editor_token_hash}) do
    GenServer.start_link(
      __MODULE__,
      {room_id, owner_pid, viewer_token_hash, editor_token_hash},
      name: via(room_id)
    )
  end

  ## GenServer callbacks

  @impl true
  def init({room_id, owner_pid, viewer_token_hash, editor_token_hash}) do
    Process.monitor(owner_pid)

    state = %{
      id: room_id,
      owner_pid: owner_pid,
      owner_ref: nil,
      viewers: %{},
      viewer_token_hash: viewer_token_hash,
      editor_token_hash: editor_token_hash,
      current_view: nil,
      current_schema: nil,
      current_page: 1,
      total_pages: 0,
      total_rows: 0,
      broadcast_timestamps: [],
      max_broadcasts_per_second: @default_max_broadcasts,
      grace_timer: nil,
      # Cursor presence: %{pid => %{name: "User", color: "#xxx", row: 5, page: 1, page_size: 50}}
      cursors: %{},
      next_color_idx: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join, pid, token_hash}, _from, state) do
    cond do
      pid == state.owner_pid ->
        # Register owner cursor if not already present
        new_state = register_cursor(state, pid, "Owner")
        {:reply, {:ok, :owner}, new_state}

      token_hash == state.editor_token_hash ->
        Process.monitor(pid)
        new_viewers = Map.put(state.viewers, pid, %{role: :editor})
        new_state = %{state | viewers: new_viewers}
        new_state = register_cursor(new_state, pid, "Editor")
        broadcast_viewer_count(new_state)

        if state.current_view do
          send(pid, {:view_update, state.current_view})
        end

        if state.current_schema do
          send(pid, {:schema_update, state.current_schema})
        end

        {:reply, {:ok, :editor}, new_state}

      token_hash == state.viewer_token_hash ->
        Process.monitor(pid)
        new_viewers = Map.put(state.viewers, pid, %{role: :viewer})
        new_state = %{state | viewers: new_viewers}
        new_state = register_cursor(new_state, pid, "Viewer")
        broadcast_viewer_count(new_state)

        if state.current_view do
          send(pid, {:view_update, state.current_view})
        end

        if state.current_schema do
          send(pid, {:schema_update, state.current_schema})
        end

        {:reply, {:ok, :viewer}, new_state}

      true ->
        {:reply, {:error, :invalid_token}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    public_state = %{
      id: state.id,
      owner_connected: state.owner_pid != nil,
      viewer_count: map_size(state.viewers),
      current_page: state.current_page,
      total_pages: state.total_pages,
      total_rows: state.total_rows,
      current_view: state.current_view,
      current_schema: state.current_schema
    }

    {:reply, {:ok, public_state}, state}
  end

  @impl true
  def handle_cast({:leave, pid}, state) do
    new_viewers = Map.delete(state.viewers, pid)
    new_state = %{state | viewers: new_viewers}
    broadcast_viewer_count(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:submit_query, from_pid, encrypted_sql}, state) do
    # Verify the sender has editor or owner role
    has_permission =
      from_pid == state.owner_pid or
        (Map.has_key?(state.viewers, from_pid) and
           state.viewers[from_pid].role == :editor)

    if has_permission and state.owner_pid != nil do
      send(state.owner_pid, {:query_request, encrypted_sql, from_pid})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:broadcast_view, encrypted_data}, state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - 1000

    # Sliding window rate limiting
    recent =
      Enum.filter(state.broadcast_timestamps, fn ts -> ts > window_start end)

    if length(recent) < state.max_broadcasts_per_second do
      new_state = %{
        state
        | current_view: encrypted_data,
          broadcast_timestamps: [now | recent]
      }

      # Relay to all viewers (direct send, not PubSub, to avoid double delivery)
      Enum.each(state.viewers, fn {pid, _info} ->
        send(pid, {:view_update, encrypted_data})
      end)

      {:noreply, new_state}
    else
      # Rate limited; drop this broadcast
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:broadcast_schema, encrypted_schema}, state) do
    new_state = %{state | current_schema: encrypted_schema}

    Enum.each(state.viewers, fn {pid, _info} ->
      send(pid, {:schema_update, encrypted_schema})
    end)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:broadcast_pii_config, columns}, state) do
    # Notify the owner to re-broadcast data with new masking, and all viewers
    all_pids = [state.owner_pid | Map.keys(state.viewers)] |> Enum.reject(&is_nil/1)

    Enum.each(all_pids, fn pid ->
      send(pid, {:pii_config_changed, columns})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:broadcast_sql, from_pid, sql}, state) do
    # Send SQL to everyone except the sender (live editor sync)
    all_pids = [state.owner_pid | Map.keys(state.viewers)] |> Enum.reject(&is_nil/1)

    Enum.each(all_pids, fn pid ->
      if pid != from_pid do
        send(pid, {:sql_sync, sql})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_pagination, page, total_pages, total_rows}, state) do
    new_state = %{
      state
      | current_page: page,
        total_pages: total_pages,
        total_rows: total_rows
    }

    Phoenix.PubSub.broadcast(
      PrivateAnalytics.PubSub,
      "room:#{state.id}",
      {:pagination_update, page, total_pages, total_rows}
    )

    {:noreply, new_state}
  end

  ## Cursor presence

  @cursor_colors ~w(#4f94ef #e94560 #22c55e #f59e0b #a855f7 #06b6d4 #ec4899 #84cc16)

  @impl true
  def handle_cast({:update_cursor, from_pid, cursor_info}, state) do
    cursors = Map.get(state, :cursors, %{})
    cursor = Map.get(cursors, from_pid, %{name: "Anonymous", color: assign_color(state)})

    cursor =
      cursor
      |> Map.put(:row, cursor_info["row"])
      |> Map.put(:page, cursor_info["page"])
      |> Map.put(:page_size, cursor_info["page_size"])

    new_cursors = Map.put(cursors, from_pid, cursor)
    new_state = Map.put(state, :cursors, new_cursors)

    all_pids = [state.owner_pid | Map.keys(state.viewers)] |> Enum.reject(&is_nil/1)

    Enum.each(all_pids, fn pid ->
      if pid != from_pid do
        # Send only OTHER people's cursors (exclude the recipient's own)
        others =
          new_cursors
          |> Enum.reject(fn {cursor_pid, _} -> cursor_pid == pid end)
          |> Enum.map(fn {_, c} -> Map.take(c, [:name, :color, :row, :page, :page_size]) end)

        send(pid, {:cursor_update, others})
      end
    end)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_name, pid, name}, state) do
    cursors = Map.get(state, :cursors, %{})

    case Map.get(cursors, pid) do
      nil ->
        color = assign_color(state)
        new_cursors = Map.put(cursors, pid, %{name: name, color: color, row: nil, page: 1, page_size: 50})
        idx = Map.get(state, :next_color_idx, 0) + 1
        {:noreply, Map.merge(state, %{cursors: new_cursors, next_color_idx: idx})}

      cursor ->
        new_cursors = Map.put(cursors, pid, %{cursor | name: name})
        {:noreply, Map.put(state, :cursors, new_cursors)}
    end
  end

  ## handle_info callbacks

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) when pid == state.owner_pid do
    # Owner disconnected. Start grace period before shutting down.
    timer = Process.send_after(self(), :grace_period_expired, @owner_grace_period_ms)
    new_state = %{state | owner_pid: nil, grace_timer: timer}

    # Notify all viewers
    Enum.each(state.viewers, fn {viewer_pid, _info} ->
      send(viewer_pid, {:room_closed})
    end)

    Phoenix.PubSub.broadcast(
      PrivateAnalytics.PubSub,
      "room:#{state.id}",
      {:room_closed}
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A viewer disconnected, clean up viewer + cursor
    new_viewers = Map.delete(state.viewers, pid)
    new_cursors = Map.delete(Map.get(state, :cursors, %{}), pid)
    new_state = %{state | viewers: new_viewers}
    new_state = if Map.has_key?(state, :cursors), do: %{new_state | cursors: new_cursors}, else: new_state
    broadcast_viewer_count(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:grace_period_expired, state) do
    if state.owner_pid == nil do
      # Owner never reconnected; shut down
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private helpers

  defp via(room_id) do
    {:via, Registry, {PrivateAnalytics.RoomRegistry, room_id}}
  end

  defp lookup(room_id) do
    case Registry.lookup(PrivateAnalytics.RoomRegistry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp assign_color(state) do
    idx = Map.get(state, :next_color_idx, 0)
    Enum.at(@cursor_colors, rem(idx, length(@cursor_colors)))
  end

  defp register_cursor(state, pid, role_label) do
    cursors = Map.get(state, :cursors, %{})

    if Map.has_key?(cursors, pid) do
      state
    else
      idx = Map.get(state, :next_color_idx, 0)
      color = Enum.at(@cursor_colors, rem(idx, length(@cursor_colors)))
      # Use role + color index for a unique default name
      name = "#{role_label} #{idx + 1}"
      cursor = %{name: name, color: color, row: nil, page: 1, page_size: 50}
      new_cursors = Map.put(cursors, pid, cursor)
      Map.merge(state, %{cursors: new_cursors, next_color_idx: idx + 1})
    end
  end

  defp broadcast_viewer_count(state) do
    count = map_size(state.viewers)

    Enum.each(state.viewers, fn {pid, _info} ->
      send(pid, {:viewer_count_update, count})
    end)

    if state.owner_pid do
      send(state.owner_pid, {:viewer_count_update, count})
    end

    Phoenix.PubSub.broadcast(
      PrivateAnalytics.PubSub,
      "room:#{state.id}",
      {:viewer_count_update, count}
    )
  end
end
