// Image filter WASM module for the latency comparison demo.
//
// Uses thread_local! + RefCell for persistent state: keeps original pixels
// so brightness/contrast adjustments are always applied to the unmodified
// source, avoiding cumulative drift.

use core::cell::RefCell;

// Re-export alloc/dealloc from exclosured_guest so the JS host can
// allocate memory in WASM linear memory.
pub use exclosured_guest::{alloc, dealloc};

struct ImageState {
    original: Vec<u8>,   // Original RGBA pixels (never mutated after load)
    processed: Vec<u8>,  // Processed RGBA pixels (result of last filter apply)
    width: u32,
    height: u32,
}

thread_local! {
    static STATE: RefCell<ImageState> = RefCell::new(ImageState {
        original: Vec::new(),
        processed: Vec::new(),
        width: 0,
        height: 0,
    });
}

/// Load RGBA image data into the module. `data_ptr` points to caller-allocated
/// memory containing `data_len` bytes of RGBA pixel data.
#[no_mangle]
pub extern "C" fn load_image(data_ptr: *const u8, data_len: usize, width: u32, height: u32) {
    let data = unsafe { core::slice::from_raw_parts(data_ptr, data_len) };
    STATE.with(|s| {
        let mut state = s.borrow_mut();
        state.original = data.to_vec();
        state.processed = data.to_vec();
        state.width = width;
        state.height = height;
    });
}

/// Apply brightness and contrast adjustments to the original pixels,
/// writing the result into the processed buffer.
///
/// - brightness: -100..100 (maps to -1.0..+1.0 added to each channel)
/// - contrast:   -100..100 (maps to a multiplier around 0.5 midpoint)
#[no_mangle]
pub extern "C" fn apply_filter(brightness: i32, contrast: i32) {
    STATE.with(|s| {
        let mut state = s.borrow_mut();
        let len = state.original.len();
        if len == 0 {
            return;
        }

        // Ensure processed buffer is the right size
        if state.processed.len() != len {
            state.processed.resize(len, 0);
        }

        let b_offset = brightness as f32 / 100.0;
        let c_factor = (contrast as f32 + 100.0) / 100.0;

        let mut i = 0;
        while i + 3 < len {
            for ch in 0..3 {
                let val = state.original[i + ch] as f32 / 255.0;
                let contrasted = (val - 0.5) * c_factor + 0.5;
                let result = contrasted + b_offset;
                state.processed[i + ch] = (result.clamp(0.0, 1.0) * 255.0) as u8;
            }
            state.processed[i + 3] = state.original[i + 3];
            i += 4;
        }
    });
}

/// Pointer to the processed pixel buffer (for JS to read via TypedArray).
#[no_mangle]
pub extern "C" fn canvas_ptr() -> *const u8 {
    STATE.with(|s| s.borrow().processed.as_ptr())
}

/// Length of the processed pixel buffer in bytes.
#[no_mangle]
pub extern "C" fn canvas_len() -> usize {
    STATE.with(|s| s.borrow().processed.len())
}
