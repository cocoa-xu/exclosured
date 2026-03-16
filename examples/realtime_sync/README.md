# Realtime Sync: Collaborative Image Editor

**Port 4003** | `cd examples/realtime_sync && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

Multiple users edit an image collaboratively. WASM is the single source of truth for pixel state: filters, drawing, and compositing all happen client-side. The server relays small operation commands via PubSub but never processes image data. Late joiners receive a snapshot + pending operations to reconstruct the current state.

## Why Use Exclosured Here?

### The problem

You're building a collaborative tool (document editor, whiteboard, design tool) where:
- Users need to see each other's changes in real-time
- The data is large (image pixels, document trees)
- Some operations are CPU-intensive (filters, transforms)
- You don't want the server processing every pixel manipulation

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **Server processes everything** | Simple consistency model, but server becomes a bottleneck. 1000 users applying blur filters = server meltdown. |
| **CRDTs (Yjs, Automerge)** | Great for text/structured data, but not designed for pixel buffers. Overhead is too high for binary data. |
| **WebRTC peer-to-peer** | No server bottleneck, but full mesh doesn't scale (N users = N(N-1)/2 connections). Signaling is fragile. |
| **Server relay + client-side WASM** | Server relays commands (tiny), each client processes locally (fast). Scales to any number of users. |

### What Exclosured adds

- WASM holds the pixel buffer in linear memory: `canvas_ptr()` gives JS direct read access, zero-copy
- Filter functions (`filter_grayscale()`, `filter_blur()`) operate in-place on the WASM buffer
- Drawing operations (`draw_line(...)`) include proper alpha blending in Rust
- The server stores an opaque snapshot (just bytes) and a list of operation commands
- `push_event("load_snapshot", %{data: base64})` sends the full state to new joiners
- `broadcast_from` distributes operations to all other users without echoing back to the sender

## Pros and Cons

**Pros:**
- Scales to any number of users (server relays small commands, not pixel data)
- WASM pixel processing is 10-50x faster than equivalent JavaScript
- Single source of truth in WASM, no state sync bugs between canvas and a separate model
- Late joiners get a snapshot + ops replay Consistent state guaranteed.
- Server never needs to understand image formats or pixel math

**Cons:**
- The initial snapshot transfer can be large (~1.6MB for 800x500 RGBA, base64 encoded ~2.1MB)
- Operations applied independently on each client can theoretically diverge (floating-point differences), mitigated by periodic snapshot baking
- No undo/redo out of the box (would need an operation log with inverse operations)
- Complex drawing operations (bezier curves, flood fill) require manual Rust implementations

## When to Choose This Pattern

- Your data is large and binary (images, audio, 3D meshes)
- Multiple users need to see changes in real-time
- Operations are CPU-intensive and benefit from Rust performance
- The server should be a dumb relay, not a processing bottleneck
- You want the option to keep data confidential (server stores opaque blobs)
