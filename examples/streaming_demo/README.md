# Streaming Results: WASM Emits, LiveView Accumulates

**Port 4009** | `cd examples/streaming_demo && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

A WASM module scans a number range for primes in batches. Each batch of discovered primes is emitted as a `"chunk"` event via `exclosured::emit()`. The LiveView accumulates results using `Exclosured.LiveView.stream_call`, which handles the chunk/done lifecycle with simple callbacks.

This demo uses a **full Cargo workspace** with the `exclosured_guest` crate for `emit()`.

## The Key Pattern: `stream_call`

```elixir
socket
|> Exclosured.LiveView.stream_call(:prime_sieve, "find_primes", [max_n],
  on_chunk: fn chunk, socket ->
    new_primes = chunk["primes"] || []
    socket
    |> update(:primes, &(&1 ++ new_primes))
    |> update(:prime_count, &(&1 + length(new_primes)))
    |> assign(progress: chunk["progress"] || 0)
  end,
  on_done: fn socket ->
    elapsed = System.monotonic_time(:millisecond) - (socket.assigns.started_at || 0)
    assign(socket, processing: false, progress: 100, elapsed_ms: elapsed)
  end
)
```

On the Rust side, each batch emits a JSON chunk:

```rust
exclosured_guest::emit("chunk", &format!(
    r#"{{"primes":[{}],"progress":{},"batch":{}}}"#,
    primes_str, progress, batch_idx + 1
));
```

## How It Works

1. User clicks "Find Primes"
2. LiveView calls `stream_call`, which pushes `wasm:call` to the browser
3. JS hook calls `find_primes(100000)` on the WASM module
4. WASM iterates batches of 1000, calling `exclosured::emit("chunk", json)` for each
5. `emit` calls `window.__exclosured.emit_event` in JS
6. JS pushes `wasm:emit` event to LiveView
7. LiveView's stream hook intercepts `{:wasm_emit, :prime_sieve, "chunk", payload}`
8. Calls `on_chunk` callback which accumulates primes and updates progress
9. After all batches, WASM emits `"done"`
10. LiveView's stream hook calls `on_done`, detaches itself

## Note on Synchronous Execution

WASM functions run synchronously in the browser's main thread. This means all `emit("chunk", ...)` calls happen during a single WASM function invocation. The JS `pushEvent` calls are queued and flushed after the function returns. From the LiveView's perspective, all chunks arrive in rapid succession as a burst.

This is fine for demonstrating the pattern. The same `stream_call` API works equally well with async scenarios (Web Workers, wasm-bindgen-futures) where chunks would arrive with real time gaps between them.

## Before and After

**Before** (manual wiring):

```elixir
def handle_info({:wasm_emit, :prime_sieve, "chunk", payload}, socket) do
  # manually accumulate
end

def handle_info({:wasm_emit, :prime_sieve, "done", payload}, socket) do
  # manually finalize
end
```

**After** (with `stream_call`):

```elixir
Exclosured.LiveView.stream_call(socket, :prime_sieve, "find_primes", [max_n],
  on_chunk: fn chunk, socket -> ... end,
  on_done: fn socket -> ... end
)
```

One call, two callbacks, automatic cleanup.
