/// Confidential image editor. All image state lives here in WASM.
///
/// JS only handles browser APIs (Canvas rendering, WebRTC, file input).
/// The server never touches pixel data. WASM is the single source of truth.

use core::cell::RefCell;

struct ImageCanvas {
    pixels: Vec<u8>, // RGBA
    width: u32,
    height: u32,
}

thread_local! {
    static CANVAS: RefCell<ImageCanvas> = RefCell::new(ImageCanvas {
        pixels: Vec::new(),
        width: 0,
        height: 0,
    });
}

// --- Memory management ---

#[no_mangle]
pub extern "C" fn alloc(size: usize) -> *mut u8 {
    let mut buf = Vec::with_capacity(size);
    let ptr = buf.as_mut_ptr();
    core::mem::forget(buf);
    ptr
}

#[no_mangle]
pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, size));
    }
}

// --- Canvas state ---

/// Initialize or resize the internal canvas.
#[no_mangle]
pub extern "C" fn init_canvas(width: u32, height: u32) {
    let len = (width * height * 4) as usize;
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        canvas.width = width;
        canvas.height = height;
        canvas.pixels = vec![0u8; len];
    });
}

/// Load RGBA pixels into the canvas. `src` points to JS-allocated memory.
#[no_mangle]
pub extern "C" fn load_pixels(src: *const u8, len: usize, width: u32, height: u32) {
    let data = unsafe { core::slice::from_raw_parts(src, len) };
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        canvas.width = width;
        canvas.height = height;
        canvas.pixels = data.to_vec();
    });
}

/// Pointer to the internal pixel buffer (for JS to read via TypedArray).
#[no_mangle]
pub extern "C" fn canvas_ptr() -> *const u8 {
    CANVAS.with(|c| c.borrow().pixels.as_ptr())
}

/// Length of the pixel buffer in bytes.
#[no_mangle]
pub extern "C" fn canvas_len() -> usize {
    CANVAS.with(|c| c.borrow().pixels.len())
}

#[no_mangle]
pub extern "C" fn canvas_width() -> u32 {
    CANVAS.with(|c| c.borrow().width)
}

#[no_mangle]
pub extern "C" fn canvas_height() -> u32 {
    CANVAS.with(|c| c.borrow().height)
}

// --- Drawing ---

/// Draw a line from (x0,y0) to (x1,y1) with a round brush.
#[no_mangle]
pub extern "C" fn draw_line(
    x0: f32, y0: f32,
    x1: f32, y1: f32,
    r: u8, g: u8, b: u8, a: u8,
    size: f32,
    eraser: u32,
) {
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        let w = canvas.width as i32;
        let h = canvas.height as i32;
        let radius = (size / 2.0).max(0.5);

        let dx = x1 - x0;
        let dy = y1 - y0;
        let dist = (dx * dx + dy * dy).sqrt();
        let steps = (dist * 2.0).max(1.0) as i32;

        for i in 0..=steps {
            let t = i as f32 / steps as f32;
            let cx = x0 + dx * t;
            let cy = y0 + dy * t;

            let r_ceil = radius.ceil() as i32;
            let min_x = (cx as i32 - r_ceil).max(0);
            let max_x = (cx as i32 + r_ceil).min(w - 1);
            let min_y = (cy as i32 - r_ceil).max(0);
            let max_y = (cy as i32 + r_ceil).min(h - 1);
            let r2 = radius * radius;

            for py in min_y..=max_y {
                for px in min_x..=max_x {
                    let dx2 = px as f32 - cx;
                    let dy2 = py as f32 - cy;
                    if dx2 * dx2 + dy2 * dy2 <= r2 {
                        let idx = ((py * w + px) * 4) as usize;
                        if idx + 3 < canvas.pixels.len() {
                            if eraser != 0 {
                                canvas.pixels[idx] = 0;
                                canvas.pixels[idx + 1] = 0;
                                canvas.pixels[idx + 2] = 0;
                                canvas.pixels[idx + 3] = 0;
                            } else {
                                let src_a = a as f32 / 255.0;
                                let dst_a = canvas.pixels[idx + 3] as f32 / 255.0;
                                let out_a = src_a + dst_a * (1.0 - src_a);
                                if out_a > 0.0 {
                                    let inv = dst_a * (1.0 - src_a);
                                    canvas.pixels[idx] = ((r as f32 * src_a + canvas.pixels[idx] as f32 * inv) / out_a) as u8;
                                    canvas.pixels[idx + 1] = ((g as f32 * src_a + canvas.pixels[idx + 1] as f32 * inv) / out_a) as u8;
                                    canvas.pixels[idx + 2] = ((b as f32 * src_a + canvas.pixels[idx + 2] as f32 * inv) / out_a) as u8;
                                    canvas.pixels[idx + 3] = (out_a * 255.0) as u8;
                                }
                            }
                        }
                    }
                }
            }
        }
    });
}

// --- Filters (operate on internal buffer) ---

#[no_mangle]
pub extern "C" fn filter_grayscale() {
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        for chunk in canvas.pixels.chunks_exact_mut(4) {
            let gray = (0.299 * chunk[0] as f32
                + 0.587 * chunk[1] as f32
                + 0.114 * chunk[2] as f32) as u8;
            chunk[0] = gray;
            chunk[1] = gray;
            chunk[2] = gray;
        }
    });
}

#[no_mangle]
pub extern "C" fn filter_invert() {
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        for chunk in canvas.pixels.chunks_exact_mut(4) {
            chunk[0] = 255 - chunk[0];
            chunk[1] = 255 - chunk[1];
            chunk[2] = 255 - chunk[2];
        }
    });
}

#[no_mangle]
pub extern "C" fn filter_sepia() {
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        for chunk in canvas.pixels.chunks_exact_mut(4) {
            let r = chunk[0] as f32;
            let g = chunk[1] as f32;
            let b = chunk[2] as f32;
            chunk[0] = (r * 0.393 + g * 0.769 + b * 0.189).min(255.0) as u8;
            chunk[1] = (r * 0.349 + g * 0.686 + b * 0.168).min(255.0) as u8;
            chunk[2] = (r * 0.272 + g * 0.534 + b * 0.131).min(255.0) as u8;
        }
    });
}

#[no_mangle]
pub extern "C" fn filter_brightness(amount: i32) {
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        for chunk in canvas.pixels.chunks_exact_mut(4) {
            chunk[0] = (chunk[0] as i32 + amount).clamp(0, 255) as u8;
            chunk[1] = (chunk[1] as i32 + amount).clamp(0, 255) as u8;
            chunk[2] = (chunk[2] as i32 + amount).clamp(0, 255) as u8;
        }
    });
}

#[no_mangle]
pub extern "C" fn filter_blur(radius: u32) {
    CANVAS.with(|c| {
        let mut canvas = c.borrow_mut();
        let w = canvas.width as usize;
        let h = canvas.height as usize;
        let r = radius as i32;

        let copy = canvas.pixels.clone();

        for y in 0..h {
            for x in 0..w {
                let mut sr: u32 = 0;
                let mut sg: u32 = 0;
                let mut sb: u32 = 0;
                let mut count: u32 = 0;

                let y0 = (y as i32 - r).max(0) as usize;
                let y1 = (y as i32 + r + 1).min(h as i32) as usize;
                let x0 = (x as i32 - r).max(0) as usize;
                let x1 = (x as i32 + r + 1).min(w as i32) as usize;

                for sy in y0..y1 {
                    for sx in x0..x1 {
                        let i = (sy * w + sx) * 4;
                        sr += copy[i] as u32;
                        sg += copy[i + 1] as u32;
                        sb += copy[i + 2] as u32;
                        count += 1;
                    }
                }

                let i = (y * w + x) * 4;
                canvas.pixels[i] = (sr / count) as u8;
                canvas.pixels[i + 1] = (sg / count) as u8;
                canvas.pixels[i + 2] = (sb / count) as u8;
            }
        }
    });
}
