//! Exclosured guest-side helpers for WASM modules.
//!
//! Provides `emit()` for sending events to LiveView, `broadcast()` for
//! inter-module communication, and memory management exports (`alloc`/`dealloc`).

extern "C" {
    fn __exclosured_emit(
        event_ptr: *const u8,
        event_len: usize,
        payload_ptr: *const u8,
        payload_len: usize,
    );

    fn __exclosured_broadcast(
        channel_ptr: *const u8,
        channel_len: usize,
        data_ptr: *const u8,
        data_len: usize,
    );
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
    unsafe {
        __exclosured_emit(
            event.as_ptr(),
            event.len(),
            payload.as_ptr(),
            payload.len(),
        );
    }
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
    unsafe {
        __exclosured_broadcast(
            channel.as_ptr(),
            channel.len(),
            data.as_ptr(),
            data.len(),
        );
    }
}

/// Allocate memory in the WASM linear memory.
///
/// Called by the JS host to allocate space before writing data
/// (strings, binary blobs) into WASM memory.
#[no_mangle]
pub extern "C" fn alloc(size: usize) -> *mut u8 {
    let mut buf = Vec::with_capacity(size);
    let ptr = buf.as_mut_ptr();
    core::mem::forget(buf);
    ptr
}

/// Deallocate memory previously allocated with `alloc`.
#[no_mangle]
pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, size));
    }
}
