# WASM AI: Text Processing (Compute Mode)

**Port 4001** | `cd examples/wasm_ai && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

A Rust WASM module runs text analysis entirely in the user's browser. The server sends input via LiveView, WASM processes it locally, and results + progress events flow back. The server never performs the heavy computation.

## Why Use Exclosured Here?

### The problem

You have CPU-intensive text processing (NLP, tokenization, regex matching, classification). Running it server-side means:
- Every request consumes server CPU
- 1000 concurrent users = 1000x the server load
- Response time includes network round-trip + server queue time

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **Server-side Elixir** | Simple, but CPU-bound work blocks the BEAM scheduler. Doesn't scale with concurrent users. |
| **Server-side with a job queue (Oban)** | Handles concurrency, but adds latency (queue + poll). User waits for a worker. |
| **Client-side JavaScript** | No server load, but JS is slow for computation. No type safety. GC pauses on large data. |
| **Client-side WASM (manual)** | Fast, but you wire up WebSocket messages, manage WASM lifecycle, build a JS bridge, all manually. |
| **Client-side WASM + Exclosured** | Fast computation, zero server load, and LiveView events handle all the plumbing. |

### What Exclosured adds

- `exclosured::emit("progress", payload)` in Rust sends events to LiveView, no custom WebSocket code
- The Mix compiler builds Rust to `.wasm` on `mix compile`, no separate build step
- LiveView's `Exclosured.LiveView.call(socket, :text_engine, "process", [input])` triggers the WASM function from Elixir, same API as any LiveView event

## Pros and Cons

**Pros:**
- Server CPU usage for this task drops to zero
- Scales linearly with users (each browser does its own work)
- Progress events flow back to LiveView in real-time
- Rust gives predictable performance: no GC pauses, no JIT warmup

**Cons:**
- Requires Rust toolchain on the build machine
- WASM cold-start: first load downloads + compiles the `.wasm` (~40KB here, ~50ms)
- Client devices vary, a weak phone is slower than your server
- Not suitable for operations that need server-side data (database queries, API calls)

## When to Choose This Pattern

- The computation is self-contained (input in, result out)
- You want to reduce server costs as user count grows
- The user is waiting for the result anyway (they can see progress)
- The data doesn't need to be combined with server-side state
