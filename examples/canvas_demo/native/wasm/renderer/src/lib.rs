use std::cell::RefCell;
use std::rc::Rc;
use wasm_bindgen::prelude::*;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

/// Shared scene state, updated from LiveView and read by the render loop.
struct SceneState {
    speed: f64,
    shape_count: usize,
    color: String,
    time: f64,
    width: f64,
    height: f64,
}

thread_local! {
    static STATE: RefCell<SceneState> = RefCell::new(SceneState {
        speed: 50.0,
        shape_count: 5,
        color: "#00d2ff".to_string(),
        time: 0.0,
        width: 800.0,
        height: 500.0,
    });
}

/// Called by the JS hook on mount. Sets up the canvas and starts
/// the requestAnimationFrame render loop.
#[wasm_bindgen]
pub fn init(canvas: HtmlCanvasElement) {
    let width = canvas.width() as f64;
    let height = canvas.height() as f64;

    STATE.with(|s| {
        let mut state = s.borrow_mut();
        state.width = width;
        state.height = height;
    });

    let ctx = canvas
        .get_context("2d")
        .unwrap()
        .unwrap()
        .dyn_into::<CanvasRenderingContext2d>()
        .unwrap();

    let f: Rc<RefCell<Option<Closure<dyn FnMut(f64)>>>> = Rc::new(RefCell::new(None));
    let g = f.clone();

    *g.borrow_mut() = Some(Closure::new(move |timestamp: f64| {
        STATE.with(|s| {
            let mut state = s.borrow_mut();
            state.time = timestamp;
        });

        render(&ctx);

        request_animation_frame(f.borrow().as_ref().unwrap());
    }));

    request_animation_frame(g.borrow().as_ref().unwrap());
}

/// Apply state update from LiveView (called via wasm:state event).
/// Accepts a JSON string as raw bytes.
#[wasm_bindgen]
pub fn apply_state(data: &[u8]) {
    if let Ok(json_str) = std::str::from_utf8(data) {
        // Simple manual JSON parsing for the small state object
        if let Some(speed) = extract_number(json_str, "speed") {
            STATE.with(|s| s.borrow_mut().speed = speed);
        }
        if let Some(count) = extract_number(json_str, "shape_count") {
            STATE.with(|s| s.borrow_mut().shape_count = count as usize);
        }
        if let Some(color) = extract_string(json_str, "color") {
            STATE.with(|s| s.borrow_mut().color = color);
        }
    }
}

fn render(ctx: &CanvasRenderingContext2d) {
    STATE.with(|s| {
        let state = s.borrow();
        let w = state.width;
        let h = state.height;
        let t = state.time / 1000.0 * state.speed / 50.0;

        // Clear
        ctx.set_fill_style_str("#0a0a1a");
        ctx.fill_rect(0.0, 0.0, w, h);

        // Draw rotating shapes
        for i in 0..state.shape_count {
            let fi = i as f64;
            let n = state.shape_count as f64;
            let angle = t + fi * std::f64::consts::TAU / n;
            let radius = 100.0 + fi * 15.0;
            let cx = w / 2.0 + angle.cos() * radius;
            let cy = h / 2.0 + angle.sin() * radius;
            let size = 20.0 + (t * 2.0 + fi).sin() * 10.0;

            // Vary alpha by index
            let alpha = 0.4 + 0.6 * (fi / n);
            let color = &state.color;
            ctx.set_fill_style_str(&format!("{}{}",
                color,
                &format!("{:02x}", (alpha * 255.0) as u8)
            ));

            ctx.begin_path();
            ctx.arc(cx, cy, size, 0.0, std::f64::consts::TAU).unwrap();
            ctx.fill();

            // Trail line to center
            ctx.set_stroke_style_str(&format!("{}40", color));
            ctx.set_line_width(1.0);
            ctx.begin_path();
            ctx.move_to(w / 2.0, h / 2.0);
            ctx.line_to(cx, cy);
            ctx.stroke();
        }

        // Center dot
        ctx.set_fill_style_str("#ffffff");
        ctx.begin_path();
        ctx.arc(w / 2.0, h / 2.0, 4.0, 0.0, std::f64::consts::TAU).unwrap();
        ctx.fill();
    });
}

fn request_animation_frame(f: &Closure<dyn FnMut(f64)>) {
    web_sys::window()
        .unwrap()
        .request_animation_frame(f.as_ref().unchecked_ref())
        .unwrap();
}

// Minimal JSON helpers (avoids serde dependency for this demo)

fn extract_number(json: &str, key: &str) -> Option<f64> {
    let pattern = format!("\"{}\":", key);
    let start = json.find(&pattern)? + pattern.len();
    let rest = json[start..].trim_start();
    let end = rest.find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-')?;
    rest[..end].parse().ok()
}

fn extract_string(json: &str, key: &str) -> Option<String> {
    let pattern = format!("\"{}\":\"", key);
    let start = json.find(&pattern)? + pattern.len();
    let end = json[start..].find('"')?;
    Some(json[start..start + end].to_string())
}
