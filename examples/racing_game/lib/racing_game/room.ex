defmodule RacingGame.Room do
  @moduledoc """
  Server-authoritative game state machine.

  Phases: lobby → countdown (30s) → racing (60s) → results (10s) → lobby

  Demonstrates key pain points solved by WASM↔LiveView:
  - Server controls NPC spawning (all clients see identical obstacles)
  - Server validates player positions (anti-cheat)
  - Server owns the game clock (no client-side timer drift)
  - Server manages lifecycle (lobby, spectators, leaderboard)
  """

  use GenServer

  @topic "room:default"
  @tick_interval 50
  @countdown_ms 30_000
  @round_ms 60_000
  @results_ms 10_000
  @min_players 2
  @max_speed 500.0
  @base_speed 200.0
  @collision_penalty_ms 1500
  @npc_min_interval 800
  @npc_max_interval 2500

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def join(player_id, name, pid) do
    GenServer.call(__MODULE__, {:join, player_id, name, pid})
  end

  def leave(player_id) do
    GenServer.cast(__MODULE__, {:leave, player_id})
  end

  def player_input(player_id, input) do
    GenServer.cast(__MODULE__, {:input, player_id, input})
  end

  def report_collision(player_id, npc_id) do
    GenServer.cast(__MODULE__, {:collision, player_id, npc_id})
  end

  def spectate_cycle(player_id, direction) do
    GenServer.call(__MODULE__, {:spectate_cycle, player_id, direction})
  end

  # --- GenServer ---

  @impl true
  def init(:ok) do
    {:ok,
     %{
       phase: :lobby,
       players: %{},
       spectators: %{},
       npcs: [],
       npc_next_id: 1,
       round_start_at: nil,
       countdown_start_at: nil,
       leaderboard: [],
       npc_timer: nil,
       tick_timer: nil
     }}
  end

  @impl true
  def handle_call({:join, player_id, name, pid}, _from, state) do
    Process.monitor(pid)

    case state.phase do
      phase when phase in [:lobby, :countdown] ->
        player = %{
          name: name,
          lane: 1,
          distance: 0.0,
          speed: @base_speed,
          last_update_at: now(),
          stunned_until: 0,
          pid: pid
        }

        state = put_in(state.players[player_id], player)
        broadcast(:game_player_joined, %{id: player_id, name: name})

        state = maybe_start_countdown(state)
        {:reply, {:player, summary(state)}, state}

      _racing_or_results ->
        state = put_in(state.spectators[player_id], %{name: name, pid: pid})
        {:reply, {:spectator, summary(state)}, state}
    end
  end

  def handle_call({:spectate_cycle, player_id, direction}, _from, state) do
    # Only spectators can cycle
    case Map.get(state.spectators, player_id) do
      nil ->
        {:reply, nil, state}

      spec ->
        ranked =
          state.players
          |> Enum.sort_by(fn {_, p} -> -p.distance end)
          |> Enum.map(fn {id, p} -> %{id: id, name: p.name, lane: p.lane, distance: p.distance} end)

        case ranked do
          [] ->
            {:reply, nil, state}

          _ ->
            target = cycle_target(ranked, spec[:watching], direction)
            spec = Map.put(spec, :watching, target.id)
            state = put_in(state.spectators[player_id], spec)
            {:reply, target, state}
        end
    end
  end

  @impl true
  def handle_cast({:leave, player_id}, state) do
    state =
      state
      |> update_in([:players], &Map.delete(&1, player_id))
      |> update_in([:spectators], &Map.delete(&1, player_id))

    broadcast(:game_player_left, %{id: player_id})
    state = maybe_cancel_countdown(state)
    {:noreply, state}
  end

  def handle_cast({:input, player_id, input}, state) do
    case Map.get(state.players, player_id) do
      nil ->
        {:noreply, state}

      player ->
        {validated_distance, validated_speed} = validate_input(player, input)

        player = %{
          player
          | lane: input["lane"],
            distance: validated_distance,
            speed: validated_speed,
            last_update_at: now()
        }

        {:noreply, put_in(state.players[player_id], player)}
    end
  end

  def handle_cast({:collision, player_id, npc_id}, state) do
    with %{} = player <- Map.get(state.players, player_id),
         %{} = npc <- Enum.find(state.npcs, &(&1.id == npc_id)),
         true <- npc.lane == player.lane do
      # Valid collision: apply penalty
      player = %{player | speed: 0.0, stunned_until: now() + @collision_penalty_ms}
      state = put_in(state.players[player_id], player)

      send_to(player.pid, :game_collision_ack, %{npc_id: npc_id, penalty_ms: @collision_penalty_ms})
      Process.send_after(self(), {:collision_recovery, player_id}, @collision_penalty_ms)
      {:noreply, state}
    else
      _ ->
        if pid = get_in(state, [:players, player_id, :pid]) do
          send_to(pid, :game_collision_reject, %{npc_id: npc_id})
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:countdown_tick, %{phase: :countdown} = state) do
    elapsed = now() - state.countdown_start_at
    remaining = max(0, div(@countdown_ms - elapsed, 1000))

    broadcast(:game_countdown, %{remaining: remaining})

    if remaining <= 0 do
      {:noreply, start_racing(state)}
    else
      Process.send_after(self(), :countdown_tick, 1000)
      {:noreply, state}
    end
  end

  def handle_info(:tick, %{phase: :racing} = state) do
    elapsed = now() - state.round_start_at
    remaining = max(0, div(@round_ms - elapsed, 1000))

    # Recover stunned players
    state = recover_stunned(state)

    # Move NPCs
    state = tick_npcs(state)

    # Broadcast positions
    players_data =
      Enum.map(state.players, fn {id, p} ->
        %{id: id, lane: p.lane, distance: p.distance, speed: p.speed}
      end)

    broadcast(:game_tick, %{players: players_data, remaining: remaining})

    if elapsed >= @round_ms do
      {:noreply, end_round(state)}
    else
      state = put_in(state.tick_timer, Process.send_after(self(), :tick, @tick_interval))
      {:noreply, state}
    end
  end

  def handle_info(:spawn_npc, %{phase: :racing} = state) do
    lane = :rand.uniform(3) - 1

    npc = %{
      id: state.npc_next_id,
      lane: lane,
      y_offset: 0.0,
      speed: 80.0 + :rand.uniform(60)
    }

    broadcast(:game_npc_spawn, npc)

    state = %{
      state
      | npcs: [npc | state.npcs],
        npc_next_id: state.npc_next_id + 1,
        npc_timer: schedule_npc()
    }

    {:noreply, state}
  end

  def handle_info({:collision_recovery, player_id}, state) do
    case Map.get(state.players, player_id) do
      nil ->
        {:noreply, state}

      player ->
        player = %{player | speed: @base_speed}
        {:noreply, put_in(state.players[player_id], player)}
    end
  end

  def handle_info(:results_done, state) do
    # Promote spectators to players for next round
    new_players =
      Enum.reduce(state.spectators, state.players, fn {id, spec}, acc ->
        Map.put(acc, id, %{
          name: spec.name,
          lane: 1,
          distance: 0.0,
          speed: @base_speed,
          last_update_at: now(),
          stunned_until: 0,
          pid: spec.pid
        })
      end)

    # Reset existing players
    new_players =
      Enum.reduce(new_players, %{}, fn {id, p}, acc ->
        Map.put(acc, id, %{p | lane: 1, distance: 0.0, speed: @base_speed, stunned_until: 0})
      end)

    state = %{
      state
      | phase: :lobby,
        players: new_players,
        spectators: %{},
        npcs: [],
        leaderboard: []
    }

    broadcast(:game_phase, %{phase: "lobby"})
    state = maybe_start_countdown(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # LiveView process died, find and remove the player
    {id, _} =
      Enum.find(Map.merge(state.players, state.spectators), {nil, nil}, fn {_, v} ->
        v.pid == pid
      end)

    if id do
      handle_cast({:leave, id}, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp maybe_start_countdown(%{phase: :lobby, players: players} = state)
       when map_size(players) >= @min_players do
    broadcast(:game_phase, %{phase: "countdown"})
    Process.send_after(self(), :countdown_tick, 1000)
    %{state | phase: :countdown, countdown_start_at: now()}
  end

  defp maybe_start_countdown(state), do: state

  defp maybe_cancel_countdown(%{phase: :countdown, players: players} = state)
       when map_size(players) < @min_players do
    broadcast(:game_phase, %{phase: "lobby"})
    %{state | phase: :lobby, countdown_start_at: nil}
  end

  defp maybe_cancel_countdown(state), do: state

  defp start_racing(state) do
    # Reset all players for the race
    players =
      Map.new(state.players, fn {id, p} ->
        {id, %{p | distance: 0.0, speed: @base_speed, lane: 1, stunned_until: 0, last_update_at: now()}}
      end)

    broadcast(:game_start, %{})
    broadcast(:game_phase, %{phase: "racing"})

    %{
      state
      | phase: :racing,
        players: players,
        npcs: [],
        npc_next_id: 1,
        round_start_at: now(),
        tick_timer: Process.send_after(self(), :tick, @tick_interval),
        npc_timer: schedule_npc()
    }
  end

  defp end_round(state) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)
    if state.npc_timer, do: Process.cancel_timer(state.npc_timer)

    leaderboard =
      state.players
      |> Enum.sort_by(fn {_, p} -> -p.distance end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{id, p}, rank} ->
        %{id: id, name: p.name, distance: Float.round(p.distance, 0), rank: rank}
      end)

    broadcast(:game_results, %{leaderboard: leaderboard})
    broadcast(:game_phase, %{phase: "results"})

    Process.send_after(self(), :results_done, @results_ms)

    %{state | phase: :results, leaderboard: leaderboard, tick_timer: nil, npc_timer: nil}
  end

  defp validate_input(player, input) do
    reported_dist = (input["distance"] || 0.0) / 1
    reported_speed = (input["speed"] || 0.0) / 1
    elapsed_s = max(now() - player.last_update_at, 1) / 1000

    max_dist = player.distance + @max_speed * elapsed_s * 1.2
    clamped_dist = min(reported_dist, max_dist)
    clamped_speed = min(reported_speed, @max_speed)

    {max(clamped_dist, player.distance), clamped_speed}
  end

  defp recover_stunned(state) do
    now = now()

    players =
      Map.new(state.players, fn {id, p} ->
        if p.speed == 0.0 and p.stunned_until > 0 and now >= p.stunned_until do
          {id, %{p | speed: @base_speed, stunned_until: 0}}
        else
          {id, p}
        end
      end)

    %{state | players: players}
  end

  defp tick_npcs(state) do
    dt = @tick_interval / 1000

    npcs =
      state.npcs
      |> Enum.map(fn npc -> %{npc | y_offset: npc.y_offset + npc.speed * dt} end)
      |> Enum.filter(fn npc -> npc.y_offset < 2000 end)

    %{state | npcs: npcs}
  end

  defp schedule_npc do
    delay = @npc_min_interval + :rand.uniform(@npc_max_interval - @npc_min_interval)
    Process.send_after(self(), :spawn_npc, delay)
  end

  defp cycle_target(ranked, current_id, direction) do
    idx = Enum.find_index(ranked, fn p -> p.id == current_id end) || 0

    next_idx =
      case direction do
        "next" -> rem(idx + 1, length(ranked))
        "prev" -> rem(idx - 1 + length(ranked), length(ranked))
        _ -> idx
      end

    Enum.at(ranked, next_idx)
  end

  defp summary(state) do
    players =
      Enum.map(state.players, fn {id, p} ->
        %{id: id, name: p.name, lane: p.lane, distance: p.distance}
      end)

    %{
      phase: Atom.to_string(state.phase),
      players: players,
      npcs: state.npcs
    }
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(RacingGame.PubSub, @topic, {:game_event, event, payload})
  end

  defp send_to(pid, event, payload) do
    send(pid, {:game_event, event, payload})
  end

  defp now, do: System.monotonic_time(:millisecond)
end
