# exclosured_guest

Guest-side Rust helpers for [Exclosured](https://github.com/cocoa-xu/exclosured) WASM modules.

This crate runs inside your WebAssembly module (the "guest") and provides:

- `emit(event, payload)`: send events to Phoenix LiveView
- `broadcast(channel, data)`: send messages to other WASM modules on the same page
- `alloc(size)` / `dealloc(ptr, size)`: memory management for JS interop

## Usage

```toml
[dependencies]
exclosured_guest = "0.1"
wasm-bindgen = "0.2"
```

```rust
use exclosured_guest as exclosured;

#[wasm_bindgen]
pub fn process(input: &str) -> i32 {
    exclosured::emit("progress", r#"{"percent": 100}"#);
    42
}
```

See the [Exclosured documentation](https://github.com/cocoa-xu/exclosured) for full setup instructions.
