# Changelog

All notable changes to this project will be documented in this file.

This project publishes to three registries. Version bumps are kept in sync.

| Registry | Package |
|---|---|
| [hex.pm](https://hex.pm/packages/exclosured) | `exclosured` (Elixir library) |
| [npmjs.com](https://www.npmjs.com/package/exclosured) | `exclosured` (JS LiveView hook) |
| [crates.io](https://crates.io/crates/exclosured_guest) | `exclosured_guest` (Rust guest crate) |

## 0.1.2

### hex.pm (exclosured@0.1.2)

- Fixed: inline WASM compiler now checks if output files exist, not just
  if the Rust source is unchanged. Prevents skipping compilation when a
  previous build was interrupted (e.g., by a concurrent download failure).

## 0.1.1

### hex.pm (exclosured@0.1.1)

- Added: `deps:` in `defwasm` now supports keyword options for Cargo features:
  `{"serde", "1", features: ["derive"]}` generates
  `serde = { version = "1", features = ["derive"] }` in Cargo.toml
- Added: `#[allow(unreachable_code)]` to generated Rust functions, suppressing
  warnings when user code has an explicit `return`
- Added: `~RUST` sigil for inline Rust code in `defwasm`. Behaves like `~S`
  (no interpolation) but enables editor extensions to provide Rust syntax
  highlighting and LSP support inside Elixir files
- Added: `defwasm` one-liner syntax:
  `defwasm :add, args: [a: :i32, b: :i32], do: "return a + b;"`
- Changed: LiveView wrapper functions in `defwasm` are only generated when
  `Exclosured.LiveView` is available (fixes compile warnings in non-Phoenix projects)
- Changed: `wasm_path/0` now returns an absolute path (works correctly in Livebook/Mix.install)

## 0.1.0

### hex.pm

Initial release of the Exclosured library.

- Mix compiler: `mix compile` builds Rust to `.wasm` via cargo + wasm-bindgen
- Incremental compilation with manifest-based staleness detection
- `Exclosured.LiveView`: `call/5`, `push_state/3`, `stream_call/5` with `on_chunk`/`on_done`
- `Exclosured.LiveView.sandbox/1`: HEEx component with `sync` attribute for declarative state binding
- `Exclosured.LiveView.sync/2`: shorthand helper for building sync maps from assigns
- Server fallback: `call/5` accepts `fallback:` option, runs Elixir function when WASM not loaded
- `Exclosured.Inline`: `defwasm` macro for inline Rust functions with `deps:` for external crates
- `Exclosured.Events`: generate Elixir structs from `/// exclosured:event` annotated Rust structs
- `Exclosured.Telemetry`: `:telemetry` events for compilation and runtime operations
- `Exclosured.Watcher`: dev file watcher for auto-recompilation
- `Exclosured.Protocol`: binary encoding for high-frequency state sync
- `mix exclosured.init`: scaffolding task for new WASM modules
- `~S` sigil support in `defwasm` for Rust code with escaped quotes

## 0.1.1

### npm (exclosured@0.1.1)

- Fixed: `const fn` renamed to `const wasmFn` (reserved word in JS strict mode)
- Fixed: `destroyed()` now calls `this.wasmBindgen.destroyed?.()` for WASM cleanup
- Added: `WasmBuffer` class in `exclosured/loader` with automatic memory cleanup via `FinalizationRegistry`
- Added: `loadAsset()` returns `WasmBuffer` instead of raw `{ ptr, len }` (no more manual `dealloc` needed)
- Added: documentation comment about shared `window.__exclosured` limitation on multi-module pages
- Changed: `loader.mjs` exports `WasmBuffer` alongside `ExclosuredLoader`

## 0.1.2

### npm (exclosured@0.1.2)

- Fixed: added `/* @vite-ignore */` to the dynamic `import()` in ExclosuredHook, preventing Vite's `import-analysis` plugin from erroring on `/wasm/` paths during development
- Same fix applied to `priv/static/exclosured_hook.js`

## 0.1.0

### npm (exclosured@0.1.0)

Initial release of the JavaScript package.

- `ExclosuredHook`: Phoenix LiveView hook for loading and communicating with WASM modules
- Declarative state sync via `data-wasm-sync` attribute and `updated()` callback
- `wasm:call`, `wasm:state`, `wasm:emit`, `wasm:result`, `wasm:error`, `wasm:ready` event protocol
- Inter-module broadcast via `window.__exclosured_bus` EventTarget
- Canvas auto-creation for interactive WASM modules
- `ExclosuredLoader`: standalone WASM loader (no LiveView required)
- `loadAsset()`: load binary assets into WASM memory

### crates.io (exclosured_guest@0.1.0)

Initial release of the Rust guest crate.

- `emit(event, payload)`: send events to Phoenix LiveView via wasm-bindgen JS imports
- `broadcast(channel, data)`: send messages to other WASM modules on the same page
- `alloc(size)` / `dealloc(ptr, size)`: memory management for JS interop
- wasm-bindgen `js_namespace = __exclosured` for emit/broadcast binding

### crates.io (exclosured_guest@0.1.1)

- Fixed: zero-size `alloc` now returns an aligned dangling pointer instead of undefined behavior
- Fixed: `dealloc` skips freeing for size 0
- Added: `repository`, `homepage`, `keywords`, `categories`, `readme` metadata to Cargo.toml
- Added: README.md with usage examples
