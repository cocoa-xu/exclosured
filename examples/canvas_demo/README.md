# Canvas Demo: Interactive Rendering (wasm-bindgen)

**Port 4002** | `cd examples/canvas_demo && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

A Rust WASM module drives a 60fps Canvas2D animation using wasm-bindgen + web-sys. LiveView pushes parameter updates (speed, color, shape count) without interrupting the render loop. Multiple users can sync the same scene via PubSub.

## Why Use Exclosured Here?

### The problem

You want a high-performance interactive visualization (charts, animations, simulations) inside a Phoenix LiveView page. Server-rendered HTML updates at best ~30fps with visible flicker. JavaScript Canvas code works but lacks type safety and suffers from GC pauses on complex scenes.

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **LiveView + SVG/HTML updates** | Simple, but each frame is a full DOM diff over WebSocket. Choppy above ~10fps. |
| **Separate SPA (React/Vue)** | Smooth rendering, but you lose LiveView's server state management. Two apps to maintain. |
| **JavaScript Canvas** | Works, but complex animations suffer from GC pauses. No compile-time type checking. |
| **WASM + manual integration** | 60fps rendering, but you build the LiveView bridge yourself. |
| **WASM + Exclosured (interactive mode)** | 60fps rendering with wasm-bindgen, LiveView pushes state changes, zero custom plumbing. |

### What Exclosured adds

- `mode: :interactive` enables wasm-bindgen, full browser API access (Canvas, WebGPU, DOM)
- WASM owns the render loop (`requestAnimationFrame`), LiveView owns the parameters
- `push_event("wasm:state", params)` sends state from Elixir to WASM without interrupting rendering
- PubSub sync lets multiple users share the same scene, each client renders locally at 60fps

## Pros and Cons

**Pros:**
- 60fps rendering without GC pauses
- LiveView manages the UI (sliders, toggles) declaratively, no client-side state framework
- Multiple users see the same scene in sync via PubSub
- Rust type safety for complex rendering math

**Cons:**
- Requires `wasm-bindgen-cli` installed on the build machine
- Larger `.wasm` output (~90KB with wasm-bindgen glue vs ~40KB raw)
- Browser API access requires web-sys feature flags; some APIs need specific features enabled
- wasm-bindgen version must match between the Rust crate and the CLI tool

## When to Choose This Pattern

- You need high-frequency visual updates (>30fps)
- The rendering logic is complex enough to benefit from Rust (physics, simulations, data viz)
- You want LiveView to control parameters while WASM handles the tight loop
- Multiple users should see a synced visualization
