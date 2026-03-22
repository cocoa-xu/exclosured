# Exclosured

Compile Rust to WebAssembly, run it in your users' browsers, and talk to it from Phoenix LiveView.

> *exclosure* (n.): an ecological term for a fenced area that excludes external interference. Your WASM code runs in a browser sandbox, isolated and secure.

## What Makes Exclosured Different

Every other Elixir+Rust library ([Rustler](https://github.com/rusterlium/rustler), [Wasmex](https://github.com/tessi/wasmex), [Orb](https://github.com/RoyalIcing/Orb)) runs code on **your server**. Exclosured runs code in **the user's browser**.

This changes three things:

**Cost.** The server does zero work for offloaded tasks. 1000 users = 1000 browsers doing their own compute. Your server scales by doing less.

**Privacy.** Data that only exists in WASM linear memory cannot reach your server. Not "we promise not to look," but "the code path makes it structurally impossible." The Private Analytics demo runs AES-256-GCM encryption, DuckDB SQL queries, and PII masking entirely in the browser. The server relays opaque encrypted blobs.

**Latency.** WASM runs locally with sub-millisecond response. The server synchronizes state at 20Hz while users get instant feedback at 60fps. No round-trip for drawing strokes, game input, or slider adjustments.

## Key Features

**Write Rust inline in Elixir** with `defwasm`. No Cargo workspace, no `.rs` files. Pull in any crate from crates.io via `deps:`:

```elixir
defmodule MyApp.Renderer do
  use Exclosured.Inline

  defwasm :render_card, args: [data: :binary], deps: [maud: "0.26"] do
    ~S"""
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

**Telemetry.** Every WASM call, emit, error, and compilation emits `:telemetry` events. Plug into LiveDashboard or any monitoring tool.

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

```heex
<%# In your LiveView template %>
<div id="wasm" phx-hook="Exclosured" data-wasm-module="my_filter"></div>
```

## Examples

Ten complete Phoenix applications in `examples/`, each with its own README explaining motivation, trade-offs, and when to use the pattern.

| # | Demo | Port | What it shows |
|---|---|---|---|
| 1 | Inline WASM | (code only) | `defwasm` macro, zero setup |
| 2 | [Text Processing](examples/wasm_ai/) | 4001 | Compute offload, progress events |
| 3 | [Interactive Canvas](examples/canvas_demo/) | 4002 | 60fps wasm-bindgen rendering, PubSub sync |
| 4 | [State Sync](examples/sync_demo/) | 4008 | Declarative `sync` attribute, wave visualizer |
| 5 | [Image Editor](examples/realtime_sync/) | 4003 | Collaborative editing, WASM as source of truth |
| 6 | [Racing Game](examples/racing_game/) | 4004 | Server-authoritative multiplayer, anti-cheat |
| 7 | [Offload Compute](examples/offload_compute/) | 4005 | Server vs WASM side-by-side timing |
| 8 | [Confidential Compute](examples/confidential_compute/) | 4006 | PII stays in browser, server sees only results |
| 9 | [Latency Compare](examples/latency_compare/) | 4007 | Server round-trip vs local WASM, feel the difference |
| 10 | [**Private Analytics**](examples/private_analytics/) | 4011 | E2E encrypted multi-user analytics with DuckDB-WASM, PII masking, Rust LiveView hooks, cursor presence |

To run any demo: `cd examples/<name> && mix deps.get && mix compile && mix phx.server`

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
