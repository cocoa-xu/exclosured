# Exclosured

Compile Rust to WebAssembly, run it in your users' browsers, and talk to it from Phoenix LiveView.

**Exclosured** lets you write performance-critical code in Rust, compile it to WASM at build time, and seamlessly integrate it with your Phoenix application. The WASM runs in an isolated sandbox on the client. Your server never touches the data.

> *exclosure* (n.): an ecological term for a fenced area that excludes external interference. Your WASM code runs in a browser sandbox, isolated and secure.

## Why?

### Offload computation to the client

Your server has finite CPU. Your users' browsers are idle. Move the heavy work (image processing, text analysis, data transformation, AI inference) to WASM running at near-native speed on the client. Your server sends input, the browser crunches it, results come back. Same user experience, 10x more headroom on your server.

### Keep sensitive data on the client

Some data shouldn't touch your server at all. Passwords, medical records, financial documents, biometric data. With Exclosured, you write the processing logic in Rust, compile it to WASM, and it runs entirely in the user's browser sandbox. The server orchestrates the workflow through LiveView but never sees the raw data. This isn't a policy promise: it's a structural guarantee. The code path makes it impossible.

### Eliminate latency for interactive features

A 100ms server round-trip is fine for a button click. It's not fine for drawing strokes on a canvas, game input at 60fps, or real-time audio effects. WASM runs locally with sub-millisecond response. The server synchronizes state at 20Hz while users get instant feedback. LiveView manages the high-level state; WASM handles the tight loop.

### And the bridge between them

Without Exclosured, you'd wire up WebSocket messages, build a custom JS bridge, manage WASM lifecycle, and handle serialization manually. With Exclosured, it's `push_event` and `handle_event`: the same API you already use in LiveView. Your Rust code calls `exclosured::emit("progress", payload)` and it arrives as a LiveView event. Your LiveView calls `Exclosured.LiveView.call(socket, :my_mod, "process", [input])` and the WASM function runs in the browser. Two languages, one communication model.

## Features

- **Mix compiler**: `mix compile` builds your Rust crates to `.wasm` automatically
- **Incremental builds**: only recompiles when `.rs` / `.toml` files change
- **LiveView integration**: bidirectional communication between Elixir and WASM via `push_event` / `handle_event`
- **Inline WASM**: define small Rust functions directly in Elixir with `defwasm` (no Cargo setup needed)
- **Unified wasm-bindgen**: all modules use wasm-bindgen for JS interop. Add `web-sys` when you need browser APIs.
- **Inter-module messaging**: multiple WASM modules on the same page can communicate via a client-side event bus
- **Dev watcher**: auto-recompile on `.rs` file changes during development

## Prerequisites

- Elixir ~> 1.15
- Rust with the `wasm32-unknown-unknown` target:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add wasm32-unknown-unknown
```

- `wasm-bindgen-cli`:

```sh
cargo install wasm-bindgen-cli
```

## Quick Start

### 1. Add the dependency

```elixir
# mix.exs
def deps do
  [{:exclosured, "~> 0.1.0"}]
end

def project do
  [
    compilers: [:exclosured] ++ Mix.compilers(),
    # ...
  ]
end
```

### 2. Scaffold a WASM module

```sh
mix exclosured.init --module my_filter
```

This creates `native/wasm/` with a Cargo workspace and a starter Rust crate.

### 3. Configure

```elixir
# config/config.exs
config :exclosured,
  modules: [
    my_filter: []
  ]
```

### 4. Compile

```sh
mix compile
```

Your `.wasm` file appears at `priv/static/wasm/my_filter/`.

### 5. Use in the browser

```javascript
import { ExclosuredHook } from "exclosured";

// Add to your LiveSocket hooks
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { Exclosured: ExclosuredHook }
});
```

```heex
<div id="wasm-filter" phx-hook="Exclosured" data-wasm-module="my_filter"></div>
```

---

## Examples

The `examples/` directory contains complete Phoenix applications, each demonstrating a different capability. See each demo's README for motivation, trade-offs, and when to use the pattern.

### Example 1: Inline WASM (Zero Setup)

Define a Rust function directly in Elixir. No Cargo workspace, no `.rs` files. The macro compiles it to a standalone `.wasm` at build time.

```elixir
defmodule MyApp.Math do
  use Exclosured.Inline

  defwasm :fibonacci, args: [n: :i32] do
    """
    let mut a: i32 = 0;
    let mut b: i32 = 1;
    for _ in 0..n {
        let tmp = b;
        b = a + b;
        a = tmp;
    }
    """
  end
end

# After `mix compile`:
MyApp.Math.wasm_url()     #=> "/wasm/my_app_math/my_app_math_bg.wasm"
MyApp.Math.wasm_exports() #=> [:fibonacci]
```

### Example 2: Text Processing

**Run it:** `cd examples/wasm_ai && mix deps.get && mix compile && mix phx.server` (port 4001)

Offload CPU-intensive work to the user's browser. The server sends input, WASM processes it locally, and results + progress events flow back.

```rust
use wasm_bindgen::prelude::*;
use exclosured_guest as exclosured;

#[wasm_bindgen]
pub fn process(input: &str) -> i32 {
    let word_count = input.split_whitespace().count();
    exclosured::emit("progress", r#"{"percent": 100}"#);
    word_count as i32
}
```

```elixir
def handle_event("analyze", %{"text" => text}, socket) do
  socket = Exclosured.LiveView.call(socket, :text_engine, "process", [text])
  {:noreply, socket}
end
```

### Example 3: Interactive Canvas (web-sys)

**Run it:** `cd examples/canvas_demo && mix deps.get && mix compile && mix phx.server` (port 4002)

A Rust WASM module drives a 60fps Canvas animation using wasm-bindgen + web-sys. LiveView pushes parameter updates without interrupting the render loop. Multiple users can sync via PubSub.

### Example 4: Declarative State Sync

**Run it:** `cd examples/sync_demo && mix deps.get && mix compile && mix phx.server` (port 4008)

LiveView assigns automatically flow to WASM via the `sync` attribute. No manual `push_event` calls. Drag sliders to control a wave visualizer rendered at 60fps in WASM:

```heex
<Exclosured.LiveView.sandbox
  module={:visualizer}
  sync={%{frequency: @frequency, amplitude: @amplitude, speed: @speed, color: @color}}
  canvas
/>
```

```elixir
# The entire event handler. No push_event anywhere.
def handle_event("update_params", params, socket) do
  {:noreply, assign(socket, frequency: params["frequency"], speed: params["speed"])}
end
```

When `@frequency` or `@speed` changes, the component re-renders, the `data-wasm-sync` attribute updates with the new JSON, and the hook's `updated()` callback pushes it to WASM's `apply_state()`. Zero boilerplate.

### Example 5: Collaborative Image Editor

**Run it:** `cd examples/realtime_sync && mix deps.get && mix compile && mix phx.server` (port 4003)

Multiple users edit an image together. WASM is the source of truth for all pixel operations. The server relays small operation commands but never processes image data.

### Example 6: Multiplayer Racing Game

**Run it:** `cd examples/racing_game && mix deps.get && mix compile && mix phx.server` (port 4004)

Server-authoritative multiplayer game. GenServer owns game state (anti-cheat, NPC spawning, timing), WASM renders at 60fps with local physics, LiveView manages lobby and leaderboard.

### Example 7: Offload Computation (Server vs WASM)

**Run it:** `cd examples/offload_compute && mix deps.get && mix compile && mix phx.server` (port 4005)

Same CSV parsing logic runs server-side (Elixir) and client-side (WASM). Side-by-side timing comparison. Uses inline `defwasm`.

### Example 8: Confidential Computation

**Run it:** `cd examples/confidential_compute && mix deps.get && mix compile && mix phx.server` (port 4006)

Password strength checker and SSN validator that process sensitive data entirely in the browser's WASM sandbox. The server only receives computed results, never the raw input.

### Example 9: Latency Comparison

**Run it:** `cd examples/latency_compare && mix deps.get && mix compile && mix phx.server` (port 4007)

Drag brightness/contrast sliders on an image. Toggle between server roundtrip mode and local WASM mode to feel the difference.

---

## Architecture

```
Build Time                          Runtime
──────────                          ───────
native/wasm/                        Phoenix LiveView
├── Cargo.toml                           │
└── my_mod/                         push_event / handle_event
    └── src/lib.rs                       │
         │                          JS Hook ◄──► WASM Instance
    cargo build                          │        (browser sandbox)
    --target wasm32                      │
         │                          pushEvent back to LiveView
    wasm-bindgen
    --target web
         │
         ▼
priv/static/wasm/my_mod/
├── my_mod.js         (JS glue)
└── my_mod_bg.wasm    (WASM binary)
```

## Configuration Reference

```elixir
config :exclosured,
  # Where Rust source lives (default)
  source_dir: "native/wasm",

  # Where .wasm files are output (default)
  output_dir: "priv/static/wasm",

  # Optimization: :none | :size | :speed (requires wasm-opt)
  optimize: :none,

  modules: [
    # Default options
    my_processor: [],

    # With Cargo features
    heavy_compute: [features: ["simd"]],

    # With canvas support (auto-creates canvas element in sandbox component)
    renderer: [canvas: true],

    # Library crate (shared code, not compiled to .wasm)
    shared: [lib: true]
  ]
```

## Inline WASM with `defwasm`

For small functions, skip the Cargo setup entirely:

```elixir
defmodule MyApp.Crypto do
  use Exclosured.Inline

  defwasm :hash_password, args: [password: :binary] do
    """
    // Runs in the browser. Password never leaves the client
    let mut hash: u32 = 5381;
    for &byte in password.iter() {
        hash = hash.wrapping_mul(33).wrapping_add(byte as u32);
    }
    // Result is in WASM memory, read by JS
    """
  end
end
```

The macro:
1. Generates a Rust crate in `_build/exclosured_inline/`
2. Compiles to `.wasm` via cargo + wasm-bindgen
3. Copies to `priv/static/wasm/`
4. Generates Elixir bindings (`MyApp.Crypto.wasm_url()`, etc.)
5. Only recompiles when the Rust source changes

## Inline vs Full Workspace

Exclosured supports two ways to write WASM modules. Use whichever fits the task.

**Inline `defwasm`**: for leaf functions where the Cargo setup would be more code than the logic itself. Zero ceremony, tiny binaries, type declarations drive all FFI boilerplate. No external crate access, no persistent state.

**Full Cargo workspace**: for anything substantial. Full crates.io ecosystem, multi-file Rust projects, `cargo test`, rust-analyzer support, `web-sys` for Canvas/WebGPU access, persistent state with `thread_local!`, shared library crates across modules.

| | Inline `defwasm` | Full workspace |
|---|---|---|
| Lines of Rust | < 50 | Any size |
| External crates | No | Yes |
| Browser APIs (web-sys) | No | Yes |
| Persistent state | No | Yes |
| Rust testing | No | `cargo test` |
| IDE support | String in Elixir | Full rust-analyzer |
| Setup cost | Zero | Cargo workspace |

## Elixir API

```elixir
# Get the browser-accessible URL for a module's .wasm
Exclosured.wasm_url(:my_mod)       #=> "/wasm/my_mod/my_mod_bg.wasm"

# Get the JS glue URL
Exclosured.wasm_js_url(:my_mod)    #=> "/wasm/my_mod/my_mod.js"

# List all configured modules
Exclosured.modules()               #=> [:my_mod, :renderer]

# LiveView: call a WASM function on the client
Exclosured.LiveView.call(socket, :my_mod, "process", [input])

# LiveView: push state to a WASM module
Exclosured.LiveView.push_state(socket, :renderer, %{speed: 50})

# LiveView: HEEx component
~H"""
<Exclosured.LiveView.sandbox module={:my_mod} />
"""
```

## Guest Crate

The `exclosured_guest` Rust crate provides helpers for WASM modules:

```rust
use exclosured_guest as exclosured;

// Send an event to LiveView
exclosured::emit("progress", r#"{"percent": 50}"#);

// Broadcast to other WASM modules on the same page (client-side only)
exclosured::broadcast("ai:result", &json_payload);

// Memory management (used by JS to write data into WASM memory)
// alloc(size) and dealloc(ptr, size) are exported automatically
```

## How Exclosured Compares to Other Elixir Libraries

Several Elixir libraries work with Rust or WASM. They solve different problems.

**[Rustler](https://github.com/rusterlium/rustler)** compiles Rust into NIFs that run inside the BEAM VM. Used by hundreds of projects for performance-critical server-side code (JSON parsing, crypto, image processing). The Rust code runs on your server, inside the BEAM. A NIF crash takes down the VM.

**[Wasmex](https://github.com/tessi/wasmex)** runs WASM modules inside the BEAM VM using Wasmtime. You load a `.wasm` file on the server and call its functions from Elixir. Useful for sandboxing untrusted code or plugin systems. Still server-side, still uses your CPU.

**[Orb](https://github.com/RoyalIcing/Orb)** lets you write WASM modules in Elixir syntax (no Rust needed). The Elixir code compiles to WASM bytecode at build time. Targets server-side execution and has a more limited instruction set than full Rust.

**Exclosured** compiles Rust to WASM and delivers it to the user's browser, with LiveView as the communication layer. None of the others do this.

| | Rustler | Wasmex | Orb | Exclosured |
|---|---|---|---|---|
| Where code runs | Server (BEAM) | Server (BEAM) | Server (BEAM) | User's browser |
| Compilation target | NIF (.so/.dll) | .wasm (server) | .wasm (server) | .wasm (browser) |
| Performance benefit | Faster server code | Sandboxed server code | Elixir-authored WASM | Offloads work from server entirely |
| Data privacy | Server sees everything | Server sees everything | Server sees everything | Server can be excluded from data path |
| LiveView integration | None | None | None | Bidirectional `push_event`/`handle_event` |

### What's unique to Exclosured

- **The execution target is the browser, not the server.** Every other library runs code on the server. Exclosured runs code on the client. This changes the cost model (server CPU drops to zero for offloaded tasks), the privacy model (server never receives sensitive data), and the latency model (local computation, no round-trip).

- **LiveView is the communication layer.** `exclosured::emit("event", payload)` in Rust arrives as a LiveView `handle_info` message. `Exclosured.LiveView.call(socket, :mod, "func", args)` triggers a WASM function in the browser. No manual WebSocket plumbing.

- **`defwasm` inline compilation.** Write Rust inside an Elixir module, compile to a browser-loadable `.wasm` at `mix compile` time. No other Elixir library offers this.

- **Server-authority + client-rendering split.** Patterns like the racing game demo (GenServer owns game state, WASM renders at 60fps, LiveView manages lobby/UI) require a separate frontend app with any other library.

### When to use the others instead

Exclosured does not replace Rustler or Wasmex:

- Need faster server-side JSON parsing or crypto? Use **Rustler**. The data is already on the server.
- Need to run user-submitted plugins safely on the server? Use **Wasmex**. Browser execution is irrelevant for server-side sandboxing.
- Want WASM without learning Rust? Consider **Orb** for server-side execution.
- Users have weak devices (IoT, old phones)? Keep computation on the server. Your server is always faster than the worst client.

Exclosured occupies the intersection of Rust performance, browser-side execution, and LiveView integration. The trade-off is complexity (three languages in one feature) and the requirement that the computation can actually happen on the client.

## License

MIT
