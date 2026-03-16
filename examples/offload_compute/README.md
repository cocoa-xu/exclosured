# Offload Compute: Server vs WASM Side-by-Side

**Port 4005** | `cd examples/offload_compute && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

The same CSV parsing logic runs in two places: server-side (Elixir) and client-side (WASM). The user clicks two buttons and compares timing. The WASM path does zero server work. The browser handles everything locally.

This demo uses **inline `defwasm`**: the Rust function is defined directly in an Elixir module, compiled to a standalone `.wasm` at build time. No Cargo workspace, no `.rs` files.

## Why Use Exclosured Here?

### The problem

Your Phoenix app does CPU work per request: data parsing, validation, transformation, report generation. Each concurrent user adds server load. At scale, you need bigger servers or a job queue, both of which increase cost and latency.

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **Server-side Elixir** | Simplest. But CPU-bound work (parsing, number crunching) blocks the scheduler. 1000 users = 1000x the load. |
| **Background jobs (Oban)** | Handles concurrency, but adds queue latency. User waits. Still uses your server CPU. |
| **Client-side JavaScript** | Zero server load, but JS is slow for computation and has no type safety for data parsing. |
| **Client-side WASM (manual setup)** | Fast, zero server load, but you need Cargo.toml, .rs files, a build step, and a custom JS bridge. |
| **Client-side WASM + Exclosured `defwasm`** | Fast, zero server load, and defined in 30 lines inside your Elixir module. No Cargo setup. |

### What `defwasm` adds

```elixir
defmodule OffloadComputeWeb.CsvParser do
  use Exclosured.Inline

  defwasm :parse_csv, args: [data: :binary] do
    """
    // 30 lines of Rust that parses CSV, computes stats, returns JSON
    """
  end
end
```

- No `native/wasm/` directory, no `Cargo.toml`, no workspace
- Compiled to a 16KB (`.wasm at build time with `opt-level = "z"` + LTO
- The type declaration `args: [data: :binary]` generates all FFI boilerplate (pointer handling, memory management)
- `OffloadComputeWeb.CsvParser.wasm_url()` gives you the URL to load in the browser

## Pros and Cons

**Pros:**
- Server CPU for this task drops to exactly zero
- 16KB .wasm`), smaller than most JavaScript libraries
- Inline definition means the parsing logic lives next to the LiveView that uses it
- Elixir compile-time constants interpolate into the Rust code via `#{}`
- Scales to unlimited users. Each browser does its own work

**Cons:**
- Inline `defwasm` can't use external Rust crates (no `serde`, no `csv` crate)
- Rust code inside an Elixir string has no IDE support (no rust-analyzer)
- Client devices vary. A low-end phone will be slower than your server
- Not suitable if the result needs server-side data (database lookups, API calls)
- The result must fit back into the input buffer (mutable `:binary` pattern)

## When to Choose This Pattern

- The operation is pure computation (input → output, no side effects)
- The logic is small enough to express in ~50 lines of Rust
- You want to eliminate server load for this specific task
- The data doesn't need to combine with server-side state
- You value simplicity over power (no crate dependencies needed)

For larger or more complex compute tasks, use a full Cargo workspace instead.
