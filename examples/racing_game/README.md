# Racing Game: Server-Authoritative Multiplayer

**Port 4004** | `cd examples/racing_game && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

A multiplayer racing game where the server manages game logic (round lifecycle, NPC spawning, anti-cheat validation, scoring) and WASM handles 60fps rendering + local physics (collision detection, ghost interpolation, input prediction). LiveView manages the lobby, spectator mode, and leaderboard declaratively.

## Why Use Exclosured Here?

### The problem

Building a real-time multiplayer game with a web stack typically forces you to choose: server-authoritative (laggy) or client-authoritative (cheatable). You need both: server authority for fairness, client rendering for responsiveness.

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **Pure server-rendered (LiveView HTML)** | Authoritative, but max ~20fps with DOM diffs. Not viable for games. |
| **Pure client-side (JS game + WebSocket)** | Smooth 60fps, but no server authority. Easy to cheat. Game state lives only in JS. |
| **Dedicated game server (C++/Go) + custom client** | Best performance, but completely separate from your Phoenix app. Two codebases, two deploy targets. |
| **Exclosured: Elixir GenServer + WASM client** | Server authority via GenServer, 60fps via WASM, lobby/leaderboard via LiveView. One codebase, one deploy. |

### What Exclosured adds: pain points solved

**1. Anti-cheat (server validates client claims)**
The Room GenServer validates every position report. If a player claims to have moved faster than `max_speed * elapsed_time * 1.2`, the server rejects it. Collision reports are checked: is the NPC actually in that lane at that position? Cheaters can't teleport or fake collisions.

**2. Synchronized NPC spawning**
The server generates NPC obstacles and broadcasts identical data to all clients. Every player sees the same obstacles at the same time. Without this, each client would generate different obstacles, which is unfair and multiplayer-incoherent.

**3. Server game clock**
Countdown, round duration, and results timing are all server-owned. No client can end the round early, extend their time, or desync the clock. Every tick includes the authoritative `remaining` seconds.

**4. 60fps from 20Hz server data**
The server sends game ticks at 20Hz (every 50ms). WASM interpolates ghost (other player) positions between ticks, producing smooth 60fps movement. Without this interpolation, other players would visibly jump 3 pixels every 50ms.

**5. LiveView for non-game UI**
The lobby, player list, name input, countdown overlay, leaderboard, and spectator mode are all standard LiveView (server-rendered HEEx templates. No client-side routing, no React, no state management library). The canvas is `phx-update="ignore"` and entirely owned by WASM.

## Pros and Cons

**Pros:**
- Server authority prevents cheating: position validation, collision verification, timing control
- 60fps client rendering with 20Hz server ticks, the best of both worlds
- LiveView handles all non-game UI (lobby, leaderboard, spectator mode) with zero client-side framework
- GenServer state machine makes game lifecycle (lobby → countdown → racing → results) explicit and testable
- WASM collision detection at 60fps catches every frame, reports to server for validation
- Mid-session spectators handled naturally; LiveView manages role assignment

**Cons:**
- Complexity: three languages (Elixir, Rust, JS) in one feature
- Server tick rate (20Hz) limits how precise server-side validation can be (50ms window for position checks)
- GenServer is single-process: one room per GenServer. Scaling to thousands of rooms needs a process registry (e.g., Horde)
- No client-side prediction rollback. If the server rejects a position, the client snaps back rather than smoothly correcting
- WASM binary is ~40KB, acceptable for a game but adds to initial page load

## When to Choose This Pattern

- You need server authority (anti-cheat, fairness, consistent state)
- The client needs high-frequency updates (games, simulations, real-time dashboards)
- You want to manage lobby/lifecycle/UI with LiveView instead of a separate frontend framework
- Your "game" might actually be a trading interface, collaborative simulation, or real-time planning tool, anything with a tight loop + server authority
