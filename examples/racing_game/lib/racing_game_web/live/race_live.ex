defmodule RacingGameWeb.RaceLive do
  use Phoenix.LiveView

  @topic "room:default"

  @impl true
  def mount(_params, _session, socket) do
    player_id = generate_id()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(RacingGame.PubSub, @topic)
    end

    {:ok,
     assign(socket,
       player_id: player_id,
       player_name: "Player_#{String.slice(player_id, 0..3)}",
       role: :pending,
       phase: :lobby,
       wasm_ready: false,
       player_list: [],
       leaderboard: []
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game-header">
      <h1>EXCLOSURED RACING</h1>
      <div class="status-bar">
        <span class="phase-badge"><%= @phase %></span>
        <span :if={@role == :spectator} class="spectator-badge">SPECTATING</span>
        <span class="wasm-status"><%= if @wasm_ready, do: "WASM OK", else: "Loading WASM..." %></span>
      </div>
    </div>

    <div :if={@phase == :lobby} class="lobby-panel">
      <h2>Lobby</h2>
      <form phx-submit="set_name">
        <input type="text" name="name" value={@player_name} placeholder="Your name" />
        <button type="submit">Update</button>
      </form>
      <ul class="player-list">
        <li :for={p <- @player_list}><%= p.name %></li>
      </ul>
      <p :if={length(@player_list) < 2} class="waiting">
        Need at least 2 players to start...
      </p>
    </div>

    <div :if={@phase == :results} class="results-panel">
      <h2>Race Results</h2>
      <ol>
        <li :for={entry <- @leaderboard}>
          <%= entry.name %> &mdash; <%= entry.distance %>m
        </li>
      </ol>
    </div>

    <div id="race-container" phx-hook="RaceGame" phx-update="ignore">
      <canvas id="game" width="400" height="700"></canvas>
    </div>

    <p class="controls-hint">
      <%= if @role == :spectator do %>
        ↑↓ to cycle between racers
      <% else %>
        ←→ to switch lanes
      <% end %>
    </p>
    """
  end

  @impl true
  def handle_event("set_name", %{"name" => name}, socket) when byte_size(name) > 0 do
    name = String.slice(name, 0..15)
    {:noreply, assign(socket, player_name: name)}
  end

  def handle_event("wasm:ready", _params, socket) do
    {role, room_state} =
      RacingGame.Room.join(
        socket.assigns.player_id,
        socket.assigns.player_name,
        self()
      )

    player_list = room_state.players

    socket =
      socket
      |> assign(
        wasm_ready: true,
        role: role,
        phase: String.to_existing_atom(room_state.phase),
        player_list: player_list
      )
      |> Phoenix.LiveView.push_event("game:init", %{
        player_id: socket.assigns.player_id,
        role: Atom.to_string(role),
        phase: room_state.phase,
        players: player_list,
        npcs: room_state.npcs
      })

    {:noreply, socket}
  end

  def handle_event("player:input", params, socket) do
    RacingGame.Room.player_input(socket.assigns.player_id, params)
    {:noreply, socket}
  end

  def handle_event("player:collision", %{"npc_id" => npc_id}, socket) do
    RacingGame.Room.report_collision(socket.assigns.player_id, npc_id)
    {:noreply, socket}
  end

  def handle_event("spectator:cycle", %{"direction" => dir}, %{assigns: %{role: :spectator}} = socket) do
    case RacingGame.Room.spectate_cycle(socket.assigns.player_id, dir) do
      nil ->
        {:noreply, socket}

      target ->
        socket =
          Phoenix.LiveView.push_event(socket, "game:spectate_target", target)

        {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  # Game events from Room GenServer via PubSub
  def handle_info({:game_event, event, payload}, socket) do
    event_name = Atom.to_string(event) |> String.replace("_", ":", global: false)

    socket =
      socket
      |> maybe_update_assigns(event, payload)
      |> Phoenix.LiveView.push_event(event_name, payload)

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp maybe_update_assigns(socket, :game_phase, %{phase: phase}) do
    assign(socket, phase: String.to_existing_atom(phase))
  end

  defp maybe_update_assigns(socket, :game_results, %{leaderboard: lb}) do
    assign(socket, leaderboard: lb)
  end

  defp maybe_update_assigns(socket, :game_player_joined, %{id: id, name: name}) do
    list = socket.assigns.player_list
    unless Enum.any?(list, &(&1.id == id)) do
      assign(socket, player_list: list ++ [%{id: id, name: name}])
    else
      socket
    end
  end

  defp maybe_update_assigns(socket, :game_player_left, %{id: id}) do
    assign(socket, player_list: Enum.reject(socket.assigns.player_list, &(&1.id == id)))
  end

  defp maybe_update_assigns(socket, _event, _payload), do: socket

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:player_id] do
      RacingGame.Room.leave(socket.assigns.player_id)
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
