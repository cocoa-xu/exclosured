defmodule LiveSvelteWasm.CollabRoom do
  @moduledoc """
  GenServer holding the authoritative document state for a collaborative editing room.
  Handles OT: transforms incoming ops against concurrent history, applies, and broadcasts.
  """
  use GenServer

  alias LiveSvelteWasm.OT

  @idle_timeout :timer.minutes(30)

  # -- Public API --------------------------------------------------------------

  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def join(room_id) do
    ensure_started(room_id)
    GenServer.call(via(room_id), {:join, self()})
  end

  def leave(room_id) do
    GenServer.cast(via(room_id), {:leave, self()})
  end

  def submit_op(room_id, client_id, base_version, op) do
    GenServer.call(via(room_id), {:submit_op, client_id, base_version, op})
  end

  def get_state(room_id) do
    GenServer.call(via(room_id), :get_state)
  end

  # -- Internals ---------------------------------------------------------------

  defp via(room_id), do: {:via, Registry, {LiveSvelteWasm.RoomRegistry, room_id}}

  defp ensure_started(room_id) do
    case Registry.lookup(LiveSvelteWasm.RoomRegistry, room_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          LiveSvelteWasm.RoomSupervisor,
          {__MODULE__, room_id}
        )

        :ok
    end
  end

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init(room_id) do
    {:ok,
     %{
       room_id: room_id,
       doc: "",
       version: 0,
       history: [],
       clients: MapSet.new()
     }, @idle_timeout}
  end

  @impl true
  def handle_call({:join, pid}, _from, state) do
    Process.monitor(pid)
    state = %{state | clients: MapSet.put(state.clients, pid)}
    {:reply, {:ok, state.doc, state.version}, state, @idle_timeout}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state.doc, state.version}, state, @idle_timeout}
  end

  def handle_call({:submit_op, client_id, base_version, op}, _from, state) do
    case transform_and_apply(state, base_version, op) do
      {:ok, new_state, transformed_op} ->
        broadcast(new_state, client_id, transformed_op)
        {:reply, {:ok, new_state.version}, new_state, @idle_timeout}

      {:error, reason} ->
        # Send resync to the client
        {:reply, {:error, reason, state.doc, state.version}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_cast({:leave, pid}, state) do
    {:noreply, %{state | clients: MapSet.delete(state.clients, pid)}, @idle_timeout}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | clients: MapSet.delete(state.clients, pid)}

    if MapSet.size(state.clients) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_timeout}
    end
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  # -- OT logic ----------------------------------------------------------------

  defp transform_and_apply(state, base_version, op) do
    if base_version < 0 or base_version > state.version do
      {:error, :invalid_version}
    else
      # Get all ops that happened since the client's base version
      ops_since = Enum.slice(state.history, base_version, state.version - base_version)

      # Transform the incoming op against each historical op
      case transform_against_history(op, ops_since) do
        {:ok, transformed_op} ->
          case OT.apply(state.doc, transformed_op) do
            {:ok, new_doc} ->
              new_state = %{
                state
                | doc: new_doc,
                  version: state.version + 1,
                  history: state.history ++ [transformed_op]
              }

              {:ok, new_state, transformed_op}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp transform_against_history(op, []), do: {:ok, op}

  defp transform_against_history(op, [hist_op | rest]) do
    case OT.transform(op, hist_op, :left) do
      {:ok, {transformed_op, _}} ->
        transform_against_history(transformed_op, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast(state, author_client_id, op) do
    Phoenix.PubSub.broadcast(
      LiveSvelteWasm.PubSub,
      "collab:#{state.room_id}",
      {:remote_op, state.version, author_client_id, op}
    )
  end
end
