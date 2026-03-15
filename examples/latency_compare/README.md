# Latency Compare -- Server Roundtrip vs Local WASM

**Port 4007** | `cd examples/latency_compare && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

Drag brightness/contrast sliders on an image. Toggle between two modes:
- **Server Roundtrip**: every slider change goes client → server → client → render. You feel the lag.
- **Local WASM**: every slider change is processed instantly in the browser. Zero network.

The latency difference is visceral and immediate.

This demo uses a **full Cargo workspace** because the WASM module needs persistent state (original pixels stored for re-applying filters from scratch on each slider change).

## Why Use Exclosured Here?

### The problem

Interactive features (drawing, scrubbing, dragging, real-time previews) need sub-16ms response times to feel smooth. A server round-trip -- even on localhost -- adds 5-50ms. On a real network, 50-200ms. This makes sliders jittery, drawing laggy, and previews choppy.

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **Server-side processing (LiveView events)** | Simple, but every interaction = WebSocket round-trip. Slider dragging feels laggy. Users notice. |
| **Client-side JavaScript** | Instant response, but pixel-level image processing in JS is slow (~50ms for a 256x256 image). GC pauses cause frame drops. |
| **Client-side WASM (manual)** | Instant + fast (~2ms for the same image). But you set up Cargo, build the bridge, manage WASM memory yourself. |
| **Exclosured (Cargo workspace)** | Instant + fast, and the Mix compiler handles the build. LiveView manages the UI. WASM handles the pixels. |

### What Exclosured adds

- `mix compile` builds the Rust crate to `.wasm` automatically -- incremental, only recompiles on change
- `thread_local!` state in WASM persists the original image across slider changes -- no re-upload per frame
- In WASM mode: slider `input` event → JS calls `apply_filter(b, c)` → reads `canvas_ptr()` → `putImageData`. Zero network.
- In server mode: slider `input` event → `phx-change` → server receives → `push_event` back → JS renders. The round-trip IS the demo.
- Toggle between modes with one button -- same UI, same result, different latency

## Pros and Cons

**Pros:**
- The difference is felt, not just measured -- users immediately prefer the WASM mode
- WASM processes a 256x256 image in ~1-2ms; the server round-trip adds 10-100ms+ on top
- Persistent WASM state means the original pixels are always available -- no re-upload, no cumulative drift
- Full Cargo workspace gives access to external crates if needed (image processing, color science)
- The server mode is a useful fallback for environments where WASM is disabled

**Cons:**
- Two code paths to maintain (server fallback + WASM). In practice, you'd pick one.
- Cargo workspace requires more setup than inline `defwasm` (Cargo.toml, directory structure)
- Larger `.wasm` binary (25KB here, but can grow with dependencies)
- WASM `thread_local!` state is per-page -- navigating away loses it (same as any client state)
- The comparison is most dramatic on real networks; on localhost, server mode is only ~5ms slower

## When to Choose This Pattern

- Any UI where the user drags, scrubs, draws, or adjusts continuously
- The computation is fast enough to run per-frame (~1-10ms) but too slow for server round-trips at 60fps
- You want to keep the server out of the hot path entirely
- The computation needs persistent state (original data, undo buffer, accumulated results)

## Architecture Note

The "server mode" in this demo is intentionally honest -- the server receives the slider values and bounces them back via `push_event`. It doesn't actually process pixels. The point is that the round-trip latency alone (5-100ms depending on network) is enough to make the interaction feel sluggish. Even if the server could process instantly, the network is the bottleneck.
