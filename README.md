# Exclosured

[![Hex.pm](https://img.shields.io/hexpm/v/exclosured)](https://hex.pm/packages/exclosured)
[![npm](https://img.shields.io/npm/v/exclosured)](https://www.npmjs.com/package/exclosured)
[![crates.io](https://img.shields.io/crates/v/exclosured_guest)](https://crates.io/crates/exclosured_guest)
[![CI](https://github.com/cocoa-xu/exclosured/actions/workflows/ci.yml/badge.svg)](https://github.com/cocoa-xu/exclosured/actions/workflows/ci.yml)

Compile Rust to WebAssembly, run it in your users' browsers, and talk to it from Phoenix LiveView.

> *exclosure* (n.): an ecological term for a fenced area that excludes external interference. Your WASM code runs in a browser sandbox, isolated and secure.

## What Makes Exclosured Different

Every other Elixir+Rust library ([Rustler](https://github.com/rusterlium/rustler), [Wasmex](https://github.com/tessi/wasmex), [Orb](https://github.com/RoyalIcing/Orb)) runs code on **your server**. Exclosured runs code in **the user's browser**.

This changes three things:

**Cost.** The server does zero work for offloaded tasks. 1000 users = 1000 browsers doing their own compute. Your server scales by doing less.

**Privacy.** Data that only exists in WASM linear memory cannot reach your server. Not "we promise not to look," but "the code path makes it structurally impossible." The Private Analytics demo runs AES-256-GCM encryption, DuckDB SQL queries, and PII masking entirely in the browser. The server relays opaque encrypted blobs.

**Latency.** WASM runs locally with sub-millisecond response. The server synchronizes state at 20Hz while users get instant feedback at 60fps. No round-trip for drawing strokes, game input, or slider adjustments.

**Resource-constrained servers.** If your Phoenix app runs on a Raspberry Pi, a Nerves device, or an edge gateway, the server has limited CPU and memory. Exclosured lets you offload computation-intensive tasks (image processing, data analysis, crypto) to the user's browser, which typically has far more resources. The embedded server only manages state and serves the UI.

## Key Features

**Write Rust inline in Elixir** with `defwasm`. No Cargo workspace, no `.rs` files. Simple functions fit on one line:

```elixir
defmodule MyApp.Math do
  use Exclosured.Inline
  defwasm :add, args: [a: :i32, b: :i32], do: "return a + b;"
end
```

Add pure-Rust crate dependencies via `deps:`:

```elixir
defmodule MyApp.Renderer do
  use Exclosured.Inline

  defwasm :render_card, args: [data: :binary], deps: [maud: "0.26"] do
    ~RUST"""
    use maud::html;
    let markup = html! { div class="card" { h3 { (title) } } };
    let bytes = markup.into_string().into_bytes();
    data[..bytes.len()].copy_from_slice(&bytes);
    return bytes.len() as i32;
    """
  end
end
```

**Write LiveView hooks in Rust.** DOM access via `web-sys`, events via a `pushEvent` callback. JS becomes a 10-line shim:

```rust
#[wasm_bindgen]
pub struct MyHook { el: HtmlElement, push_event: js_sys::Function }

#[wasm_bindgen]
impl MyHook {
    pub fn mounted(&mut self) { /* full DOM access, event listeners, canvas rendering */ }
    pub fn on_event(&self, event: &str, payload: &str) { /* handle server events */ }
}
```

**Declarative state sync.** LiveView assigns flow to WASM automatically:

```heex
<Exclosured.LiveView.sandbox
  module={:visualizer}
  sync={Exclosured.LiveView.sync(assigns, ~w(speed color count)a)}
  canvas
/>
```

No `push_event` calls. When `@speed` changes, the component re-renders and the hook pushes the new value to WASM's `apply_state()`.

**Streaming results.** WASM emits incremental chunks, LiveView accumulates:

```elixir
Exclosured.LiveView.stream_call(socket, :processor, "analyze", [data],
  on_chunk: fn chunk, socket -> update(socket, :results, &[chunk | &1]) end,
  on_done: fn socket -> assign(socket, processing: false) end
)
```

**Server fallback.** If WASM fails to load, the same `call/5` runs an Elixir function instead. Result shape is identical:

```elixir
Exclosured.LiveView.call(socket, :my_mod, "process", [input],
  fallback: fn [input] -> process_on_server(input) end
)
```

**Typed events.** Annotate Rust structs, get Elixir structs at compile time:

```rust
/// exclosured:event
pub struct ProgressEvent { pub percent: u32, pub stage: String }
```

```elixir
defmodule MyApp.Events do
  use Exclosured.Events, source: "native/wasm/my_mod/src/lib.rs"
end
# MyApp.Events.ProgressEvent.from_payload(payload) => %ProgressEvent{percent: 75, stage: "done"}
```

**Telemetry.** Every WASM operation emits `:telemetry` events. Plug into LiveDashboard or any monitoring tool.

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

```elixir
:telemetry.attach_many("my-handler",
  [[:exclosured, :compile, :stop], [:exclosured, :wasm, :call]],
  fn event, measurements, metadata, _ ->
    Logger.info("[exclosured] #{inspect(event)} #{inspect(metadata)}")
  end, nil)
```

## Prerequisites

- Elixir >= 1.15 and Erlang/OTP >= 26
- Rust with the wasm32 target and wasm-bindgen:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli
```

## Quick Start

```elixir
# mix.exs
def project do
  [compilers: [:exclosured] ++ Mix.compilers(), ...]
end

def deps do
  [{:exclosured, "~> 0.1.0"}]
end
```

```sh
mix exclosured.init --module my_filter  # scaffold Cargo workspace + starter crate
mix compile                              # builds Rust to .wasm automatically
```

```elixir
# config/config.exs
config :exclosured, modules: [my_filter: []]
```

Install the JS hook (one copy shared across all packages that use Exclosured):

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

```heex
<%# In your LiveView template %>
<div id="wasm" phx-hook="Exclosured" data-wasm-module="my_filter"></div>
```

## Examples

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
| 13 | [Kino Data Explorer](examples/kino_exclosured/) | Livebook smart cell, WASM stats with JS fallback |
| 14 | [**Brotli Compress**](examples/brotli_compress/) | Brotli (WASM) vs Gzip (JS) compression benchmark |
| 15 | [**Matrix Multiply**](examples/matrix_mul/) | nalgebra (WASM) vs JS nested loops, GFLOPS comparison |

Most demos run with `cd examples/<name> && mix setup && mix phx.server`. Some examples require additional setup (npm, Vite, etc.); see each example's README for details.

## Inline vs Full Workspace

| | Inline `defwasm` | Full Cargo workspace |
|---|---|---|
| Lines of Rust | < 50 | Any size |
| External crates | Yes (via `deps:`) | Yes |
| Browser APIs (web-sys) | No | Yes |
| LiveView hooks in Rust | No | Yes |
| Persistent state | No | Yes |
| Rust testing | No | `cargo test` |
| IDE support | String in Elixir | Full rust-analyzer |
| Setup cost | Zero | Cargo workspace |

## Configuration

```elixir
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

## API Reference

```elixir
# URLs
Exclosured.wasm_url(:my_mod)        #=> "/wasm/my_mod/my_mod_bg.wasm"
Exclosured.wasm_js_url(:my_mod)     #=> "/wasm/my_mod/my_mod.js"

# Call WASM from LiveView
Exclosured.LiveView.call(socket, :mod, "func", [args])
Exclosured.LiveView.call(socket, :mod, "func", [args], fallback: fn [args] -> ... end)

# Push state
Exclosured.LiveView.push_state(socket, :mod, %{key: value})

# Declarative sync (auto-pushes on assign change)
Exclosured.LiveView.sync(assigns, [:key1, :key2, renamed: :original_key])

# Streaming results
Exclosured.LiveView.stream_call(socket, :mod, "func", [args],
  on_chunk: fn chunk, socket -> ... end,
  on_done: fn socket -> ... end
)

# HEEx component
~H"<Exclosured.LiveView.sandbox module={:mod} sync={...} canvas />"
```

```rust
// Rust guest crate
exclosured::emit("event_name", r#"{"key": "value"}"#);  // send to LiveView
exclosured::broadcast("channel", &payload);               // send to other WASM modules
```

## Code Examples

### Inline WASM with `defwasm`

Define a Rust function directly in Elixir. No Cargo workspace, no `.rs` files:

```elixir
defmodule MyApp.Crypto do
  use Exclosured.Inline

  defwasm :hash_password, args: [password: :binary] do
    """
    let mut hash: u32 = 5381;
    for &byte in password.iter() {
        hash = hash.wrapping_mul(33).wrapping_add(byte as u32);
    }
    """
  end
end

# After mix compile:
MyApp.Crypto.wasm_url()     #=> "/wasm/my_app_crypto/my_app_crypto_bg.wasm"
MyApp.Crypto.wasm_exports() #=> [:hash_password]
```

### External Crates via `deps:`

Add crate dependencies that compile to wasm32. Pure-Rust crates generally work; crates with C/system dependencies do not. Enable Cargo features with a keyword list:

```elixir
defwasm :render_card, args: [data: :binary], deps: [maud: "0.26"] do
  ~RUST"""
  use maud::html;

  let markup = html! {
      div class="card" {
          h3 { (title) }
          ul {
              @for item in &items {
                  li { (item) }
              }
          }
      }
  };
  let bytes = markup.into_string().into_bytes();
  data[..bytes.len()].copy_from_slice(&bytes);
  return bytes.len() as i32;
  """
end
```

To enable crate features (e.g. serde's `derive`), pass a keyword list as the third element:

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

### Full Cargo Workspace

For larger modules with persistent state, browser APIs, and multiple files:

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

### LiveView Hook in Rust

Write DOM-interacting hooks entirely in Rust, with JS as a thin shim:

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
        // Set up textarea, syntax highlighting overlay, keyboard shortcuts
        // All via web-sys. No JS needed.
    }

    pub fn on_event(&self, event: &str, payload: &str) {
        // Handle events from the server (e.g., sync SQL from another editor)
    }
}
```

```javascript
// The entire JS hook (10 lines):
const mod = await import("/wasm/my_hook/my_hook.js");
await mod.default("/wasm/my_hook/my_hook_bg.wasm");
const pushFn = (event, payload) => this.pushEvent(event, JSON.parse(payload));
this._hook = new mod.SqlEditorHook(this.el, pushFn);
this._hook.mounted();
this.handleEvent("sync_sql", (d) => this._hook.on_event("set_sql", d.sql));
```

### Typed Events from Rust Structs

Annotate Rust structs, get Elixir structs at compile time:

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

# Pattern match on typed structs instead of raw maps:
def handle_info({:wasm_emit, :pipeline, "stage_complete", payload}, socket) do
  event = MyApp.Events.StageComplete.from_payload(payload)
  # event.stage_name    => "validate"
  # event.items_processed => 500
  # event.duration_ms   => 42
end
```

## Compared to Other Libraries

| | Rustler | Wasmex | Orb | Exclosured |
|---|---|---|---|---|
| Where code runs | Server | Server | Server | Browser |
| Compilation target | NIF | .wasm (server) | .wasm (server) | .wasm (browser) |
| Server CPU usage | Increases | Increases | Increases | Zero for offloaded tasks |
| Data privacy | Server sees all | Server sees all | Server sees all | Server can be excluded |
| LiveView integration | None | None | None | Bidirectional |

Use **Rustler** for server-side performance. Use **Wasmex** for server-side sandboxing. Use **Exclosured** when the computation should happen in the browser.

## License

MIT
