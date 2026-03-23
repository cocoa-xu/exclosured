# Exclosured

[![Hex.pm](https://img.shields.io/hexpm/v/exclosured)](https://hex.pm/packages/exclosured)
[![npm](https://img.shields.io/npm/v/exclosured)](https://www.npmjs.com/package/exclosured)
[![crates.io](https://img.shields.io/crates/v/exclosured_guest)](https://crates.io/crates/exclosured_guest)
[![CI](https://github.com/cocoa-xu/exclosured/actions/workflows/ci.yml/badge.svg)](https://github.com/cocoa-xu/exclosured/actions/workflows/ci.yml)

Compile Rust to WebAssembly, run it in your users' browsers, and talk to it from Phoenix LiveView.

> *exclosure* (n.): an ecological term for a fenced area that excludes external interference. Your WASM code runs in a browser sandbox, isolated and secure.

## Features

Every other Elixir+Rust library ([Rustler](https://github.com/rusterlium/rustler), [Wasmex](https://github.com/tessi/wasmex), [Orb](https://github.com/RoyalIcing/Orb)) runs code on **your server**. Exclosured runs code in **the user's browser**.

- **Zero server cost.** 1000 users = 1000 browsers doing their own compute. Your server scales by doing less.
- **Structural privacy.** Data in WASM linear memory cannot reach your server. Not a policy, a code path.
- **Local latency.** WASM runs at sub-millisecond speed. No round-trip for drawing strokes, game input, or slider adjustments.
- **Resource-constrained servers.** Offload heavy tasks to the browser from a Raspberry Pi, Nerves device, or edge gateway.

### What you can do

| Capability | Description |
|---|---|
| **Inline Rust** | Write Rust inside Elixir with `defwasm`. No Cargo workspace needed. |
| **`~RUST` sigil** | Editor-friendly sigil for syntax highlighting and LSP support. |
| **External crates** | Add crate dependencies via `deps:` with feature support. |
| **Rust LiveView hooks** | Write DOM-interacting hooks in Rust, JS becomes a thin shim. |
| **Declarative sync** | LiveView assigns flow to WASM automatically via `sync`. |
| **Streaming results** | WASM emits incremental chunks, LiveView accumulates. |
| **Server fallback** | If WASM fails to load, run an Elixir function instead. |
| **Typed events** | Annotate Rust structs, get Elixir structs at compile time. |
| **Telemetry** | Every WASM operation emits `:telemetry` events. |

### Compared to other libraries

| | Rustler | Wasmex | Orb | Exclosured |
|---|---|---|---|---|
| Where code runs | Server | Server | Server | Browser |
| Compilation target | NIF | .wasm (server) | .wasm (server) | .wasm (browser) |
| Server CPU usage | Increases | Increases | Increases | Zero for offloaded tasks |
| Data privacy | Server sees all | Server sees all | Server sees all | Server can be excluded |
| LiveView integration | None | None | None | Bidirectional |

## Resources

| Package | Purpose |
|---|---|
| [exclosured](https://hex.pm/packages/exclosured) (Hex) | Core Elixir library |
| [exclosured](https://www.npmjs.com/package/exclosured) (npm) | JS LiveView hook |
| [exclosured_guest](https://crates.io/crates/exclosured_guest) (crates.io) | Rust guest crate |
| [exclosured_precompiled](https://hex.pm/packages/exclosured_precompiled) (Hex) | Precompiled WASM distribution |
| [exclosured-precompiled-action](https://github.com/cocoa-xu/exclosured-precompiled-action) | GitHub Action for CI precompilation |
| [exclosured_example](https://github.com/cocoa-xu/exclosured_example) | Example library with precompilation |

- [Developer Guide](DEVELOPER.md)
- [Changelog](CHANGELOG.md)

## Demos

Fifteen example applications in `examples/`, each with its own README.

| # | Demo | What it shows |
|---|---|---|
| 1 | Inline WASM | `defwasm` macro, zero setup |
| 2 | [Text Processing](examples/wasm_ai/) | Compute offload, progress events |
| 3 | [Interactive Canvas](examples/canvas_demo/) | 60fps wasm-bindgen rendering, PubSub sync |
| 4 | [State Sync](examples/sync_demo/) | Declarative `sync` attribute, wave visualizer |
| 5 | [Image Editor](examples/realtime_sync/) | Collaborative editing, WASM as source of truth |
| 6 | [Racing Game](examples/racing_game/) | Server-authoritative multiplayer, anti-cheat |
| 7 | [Offload Compute](examples/offload_compute/) | Server vs WASM side-by-side timing |
| 8 | [Confidential Compute](examples/confidential_compute/) | PII stays in browser, server sees only results |
| 9 | [Latency Compare](examples/latency_compare/) | Server round-trip vs local WASM |
| 10 | [**Private Analytics**](examples/private_analytics/) | E2E encrypted analytics, DuckDB-WASM, Rust hooks |
| 11 | [LiveVue + WASM](examples/live_vue_wasm/) | Vue.js integration, real-time stats dashboard |
| 12 | [LiveSvelte + WASM](examples/live_svelte_wasm/) | Svelte integration, WASM markdown editor + KaTeX |
| 13 | [Kino Data Explorer](examples/kino_exclosured/) | Livebook smart cell, inline WASM calculator |
| 14 | [**Brotli Compress**](examples/brotli_compress/) | Brotli (WASM) vs Gzip (JS) compression benchmark |
| 15 | [**Matrix Multiply**](examples/matrix_mul/) | 5-way benchmark: JS vs WASM vs WebGPU vs TF.js vs OpenCV |

Most demos run with `cd examples/<name> && mix setup && mix phx.server`. Some require npm setup; see each example's README.

## Installation

### Prerequisites

- Elixir >= 1.15 and Erlang/OTP >= 26
- Rust with the wasm32 target and wasm-bindgen:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli
```

### Add to your project

```elixir
# mix.exs
def project do
  [compilers: [:exclosured] ++ Mix.compilers(), ...]
end

def deps do
  [{:exclosured, "~> 0.1.1"}]
end
```

### Install the JS hook

```sh
cd assets && npm install exclosured
```

```javascript
// assets/js/app.js
import { ExclosuredHook } from "exclosured";

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { Exclosured: ExclosuredHook }
});
```

### Scaffold a WASM module

```sh
mix exclosured.init --module my_filter
```

### Configure

```elixir
# config/config.exs
config :exclosured,
  source_dir: "native/wasm",         # where Rust source lives
  output_dir: "priv/static/wasm",    # where .wasm files go
  optimize: :none,                    # :none | :size | :speed (requires wasm-opt)
  modules: [
    my_processor: [],                 # default options
    renderer: [canvas: true],         # auto-creates canvas in sandbox component
    shared: [lib: true]               # library crate, not compiled to .wasm
  ]
```

## Usage

### Inline WASM with `defwasm`

Simple functions fit on one line:

```elixir
defmodule MyApp.Math do
  use Exclosured.Inline
  defwasm :add, args: [a: :i32, b: :i32], do: ~RUST"a + b"
end
```

Multi-line Rust with the `~RUST` sigil:

```elixir
defmodule MyApp.Crypto do
  use Exclosured.Inline

  defwasm :hash_password, args: [password: :binary] do
    ~RUST"""
    let mut hash: u32 = 5381;
    for &byte in password.iter() {
        hash = hash.wrapping_mul(33).wrapping_add(byte as u32);
    }
    hash as i32
    """
  end
end
```

Add crate dependencies with feature flags:

```elixir
defwasm :parse, args: [data: :binary],
  deps: [{"serde", "1", features: ["derive"]}, {"serde_json", "1"}] do
  ~RUST"""
  #[derive(serde::Deserialize)]
  struct Input { name: String, value: f64 }

  let input: Input = serde_json::from_str(
      core::str::from_utf8(data).unwrap_or("{}")
  ).unwrap();
  // ...
  """
end
```

### Inline vs Full Workspace

| | Inline `defwasm` | Full Cargo workspace |
|---|---|---|
| Lines of Rust | < 50 | Any size |
| External crates | Yes (via `deps:`) | Yes |
| Browser APIs (web-sys) | No | Yes |
| LiveView hooks in Rust | No | Yes |
| Persistent state | No | Yes |
| Rust testing | No | `cargo test` |
| IDE support | `~RUST` sigil | Full rust-analyzer |
| Setup cost | Zero | Cargo workspace |

### Full Cargo Workspace

For larger modules with persistent state and browser APIs:

```rust
// native/wasm/my_module/src/lib.rs
use wasm_bindgen::prelude::*;
use exclosured_guest as exclosured;

#[wasm_bindgen]
pub fn process(input: &str) -> i32 {
    let result = input.split_whitespace().count();
    exclosured::emit("progress", r#"{"percent": 100}"#);
    result as i32
}
```

```elixir
# In your LiveView
def handle_event("analyze", %{"text" => text}, socket) do
  socket = Exclosured.LiveView.call(socket, :my_module, "process", [text])
  {:noreply, socket}
end

def handle_info({:wasm_result, :my_module, "process", count}, socket) do
  {:noreply, assign(socket, word_count: count)}
end
```

### LiveView Hooks in Rust

Write DOM-interacting hooks entirely in Rust. JS becomes a thin shim:

```rust
#[wasm_bindgen]
pub struct SqlEditorHook {
    container: HtmlElement,
    push_event: js_sys::Function,
}

#[wasm_bindgen]
impl SqlEditorHook {
    #[wasm_bindgen(constructor)]
    pub fn new(container: HtmlElement, push_event: js_sys::Function) -> Self { ... }

    pub fn mounted(&mut self) {
        // Set up textarea, syntax highlighting, keyboard shortcuts
        // All via web-sys. No JS needed.
    }

    pub fn on_event(&self, event: &str, payload: &str) {
        // Handle events from the server
    }
}
```

```javascript
// The entire JS hook (6 lines):
const mod = await import("/wasm/my_hook/my_hook.js");
await mod.default("/wasm/my_hook/my_hook_bg.wasm");
const pushFn = (event, payload) => this.pushEvent(event, JSON.parse(payload));
this._hook = new mod.SqlEditorHook(this.el, pushFn);
this._hook.mounted();
this.handleEvent("sync_sql", (d) => this._hook.on_event("set_sql", d.sql));
```

### Declarative State Sync

LiveView assigns flow to WASM automatically. No `push_event` calls:

```heex
<Exclosured.LiveView.sandbox
  module={:visualizer}
  sync={Exclosured.LiveView.sync(assigns, ~w(speed color count)a)}
  canvas
/>
```

When `@speed` changes, the component re-renders and the hook pushes the new value to WASM's `apply_state()`.

### Streaming Results

WASM emits incremental chunks, LiveView accumulates:

```elixir
Exclosured.LiveView.stream_call(socket, :processor, "analyze", [data],
  on_chunk: fn chunk, socket -> update(socket, :results, &[chunk | &1]) end,
  on_done: fn socket -> assign(socket, processing: false) end
)
```

### Server Fallback

If WASM fails to load, the same `call/5` runs an Elixir function instead. Result shape is identical:

```elixir
Exclosured.LiveView.call(socket, :my_mod, "process", [input],
  fallback: fn [input] -> process_on_server(input) end
)
```

### Rust Guest API

```rust
exclosured::emit("event_name", r#"{"key": "value"}"#);  // send to LiveView
exclosured::broadcast("channel", &payload);               // send to other WASM modules
```

### LiveView API Reference

```elixir
Exclosured.LiveView.call(socket, :mod, "func", [args])
Exclosured.LiveView.call(socket, :mod, "func", [args], fallback: fn [args] -> ... end)
Exclosured.LiveView.push_state(socket, :mod, %{key: value})
Exclosured.LiveView.sync(assigns, [:key1, :key2, renamed: :original_key])
Exclosured.LiveView.stream_call(socket, :mod, "func", [args], on_chunk: ..., on_done: ...)
```

### Typed Events

```rust
/// exclosured:event
pub struct StageComplete {
    pub stage_name: String,
    pub items_processed: u32,
    pub duration_ms: u32,
}
```

```elixir
defmodule MyApp.Events do
  use Exclosured.Events, source: "native/wasm/pipeline/src/lib.rs"
end

def handle_info({:wasm_emit, :pipeline, "stage_complete", payload}, socket) do
  event = MyApp.Events.StageComplete.from_payload(payload)
  # event.stage_name => "validate"
end
```

### Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:exclosured, :compile, :start]` | `system_time` | `module` |
| `[:exclosured, :compile, :stop]` | `duration` | `module`, `wasm_size` |
| `[:exclosured, :compile, :error]` | `duration` | `module`, `error` |
| `[:exclosured, :wasm, :call]` | | `module`, `func` |
| `[:exclosured, :wasm, :result]` | | `module`, `func` |
| `[:exclosured, :wasm, :emit]` | | `module`, `event` |
| `[:exclosured, :wasm, :error]` | | `module`, `func`, `error` |
| `[:exclosured, :wasm, :ready]` | | `module` |

## Deployment

### Endpoint setup

Add `"wasm"` to your endpoint's `Plug.Static` `:only` list:

```elixir
plug Plug.Static,
  at: "/",
  from: :my_app,
  only: ~w(assets wasm fonts images favicon.ico robots.txt)
```

### Production build

```sh
mix compile                    # compiles Rust to .wasm
mix phx.digest                 # fingerprints static assets
MIX_ENV=prod mix release       # builds the release
```

The `.wasm` files in `priv/static/wasm/` are served like any other static asset. No special server-side runtime is needed.

### CSP headers

If your app uses Content Security Policy, add:

```
script-src 'wasm-unsafe-eval';
```

### Precompiled distribution

If you are publishing a library that includes WASM modules, you can
distribute precompiled binaries so your users don't need the Rust
toolchain. Use [exclosured_precompiled](https://hex.pm/packages/exclosured_precompiled):

```elixir
# In your library
defmodule MyLib.Precompiled do
  use ExclosuredPrecompiled,
    otp_app: :my_lib,
    base_url: "https://github.com/user/my_lib/releases/download/v0.1.0",
    version: "0.1.0",
    modules: [:my_processor]
end
```

Build, package, and upload in one workflow:

```sh
# Locally: compile from source, package into .tar.gz + .sha256
mix exclosured_precompiled.precompile

# Upload to GitHub Release
gh release create v0.1.0 _build/precompiled/*.tar.gz _build/precompiled/*.sha256

# Generate checksum file for Hex package
mix exclosured_precompiled.checksum --local
```

Or automate with the [GitHub Action](https://github.com/cocoa-xu/exclosured-precompiled-action):

```yaml
- uses: cocoa-xu/exclosured-precompiled-action@v1
  with:
    project-version: ${{ github.ref_name }}
```

See the [exclosured_example](https://github.com/cocoa-xu/exclosured_example)
repository for a complete working example with CI automation.

## License

MIT
