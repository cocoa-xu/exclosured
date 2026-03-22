//! Exclosured guest-side helpers for WASM modules.
//!
//! Provides `emit()` for sending events to LiveView, `broadcast()` for
//! inter-module communication, and memory management exports (`alloc`/`dealloc`).

use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = __exclosured)]
    fn emit_event(event: &str, payload: &str);
    #[wasm_bindgen(js_namespace = __exclosured)]
    fn broadcast_event(channel: &str, data: &str);
}

/// Emit an event to the LiveView server.
///
/// The event name and JSON payload are sent through the JS hook
/// and arrive as a `{:wasm_emit, module, event, payload}` message
/// in the LiveView process.
///
/// # Example
///
/// ```rust
/// exclosured_guest::emit("progress", r#"{"percent": 50}"#);
/// ```
pub fn emit(event: &str, payload: &str) {
    emit_event(event, payload);
}

/// Broadcast a message to other WASM modules on the same page.
///
/// This does NOT go through the server. The message is dispatched
/// via the client-side JS event bus to other modules that have
/// subscribed to the given channel.
///
/// # Example
///
/// ```rust
/// exclosured_guest::broadcast("ai:result", r#"{"label": "cat"}"#);
/// ```
pub fn broadcast(channel: &str, data: &str) {
    broadcast_event(channel, data);
}

/// Allocate memory in the WASM linear memory.
///
/// Called by the JS host to allocate space before writing data
/// (strings, binary blobs) into WASM memory.
///
/// Returns an aligned, non-null pointer even for size 0.
#[no_mangle]
pub extern "C" fn alloc(size: usize) -> *mut u8 {
    if size == 0 {
        // Return a well-aligned dangling pointer instead of
        // invoking the allocator with a zero-size layout.
        return core::mem::align_of::<u8>() as *mut u8;
    }
    let mut buf = Vec::with_capacity(size);
    let ptr = buf.as_mut_ptr();
    core::mem::forget(buf);
    ptr
}

/// Deallocate memory previously allocated with `alloc`.
///
/// Skips deallocation for size 0 (which returns a dangling pointer from `alloc`).
#[no_mangle]
pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
    if size == 0 {
        return;
    }
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, size));
    }
}
