use std::cell::RefCell;
use std::f64::consts::{PI, TAU};
use std::rc::Rc;
use wasm_bindgen::prelude::*;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

/// Persistent wave state, updated from LiveView via declarative sync
/// and read each frame by the render loop.
struct WaveState {
    frequency: f64,
    amplitude: f64,
    speed: f64,
    color_r: u8,
    color_g: u8,
    color_b: u8,
    wave_type: WaveType,
    time: f64,
    width: f64,
    height: f64,
}

#[derive(Clone, Copy)]
enum WaveType {
    Sine,
    Square,
    Sawtooth,
}

thread_local! {
    static STATE: RefCell<WaveState> = RefCell::new(WaveState {
        frequency: 5.0,
        amplitude: 80.0,
        speed: 50.0,
        color_r: 0,
        color_g: 210,
        color_b: 255,
        wave_type: WaveType::Sine,
        time: 0.0,
        width: 600.0,
        height: 300.0,
    });
}

/// Called by the JS hook on mount. Sets up the canvas context and starts
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

/// Apply state update from LiveView via the declarative sync attribute.
/// Receives a JSON string as raw bytes.
#[wasm_bindgen]
pub fn apply_state(data: &[u8]) {
    let json_str = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => return,
    };

    STATE.with(|s| {
        let mut state = s.borrow_mut();

        if let Some(v) = extract_number(json_str, "frequency") {
            state.frequency = v;
        }
        if let Some(v) = extract_number(json_str, "amplitude") {
            state.amplitude = v;
        }
        if let Some(v) = extract_number(json_str, "speed") {
            state.speed = v;
        }
        if let Some(color) = extract_string(json_str, "color") {
            if let Some((r, g, b)) = parse_hex_color(&color) {
                state.color_r = r;
                state.color_g = g;
                state.color_b = b;
            }
        }
        if let Some(wt) = extract_string(json_str, "wave_type") {
            state.wave_type = match wt.as_str() {
                "square" => WaveType::Square,
                "sawtooth" => WaveType::Sawtooth,
                _ => WaveType::Sine,
            };
        }
    });
}

/// Compute the wave value at a given phase for the specified wave type.
fn wave_value(wave_type: WaveType, phase: f64) -> f64 {
    match wave_type {
        WaveType::Sine => phase.sin(),
        WaveType::Square => {
            if phase.sin() >= 0.0 {
                1.0
            } else {
                -1.0
            }
        }
        WaveType::Sawtooth => {
            // Normalize phase to [0, TAU), then map to [-1, 1]
            let normalized = ((phase % TAU) + TAU) % TAU;
            (normalized / PI) - 1.0
        }
    }
}

fn render(ctx: &CanvasRenderingContext2d) {
    STATE.with(|s| {
        let state = s.borrow();
        let w = state.width;
        let h = state.height;
        let t = state.time / 1000.0 * state.speed / 50.0;
        let mid_y = h / 2.0;
        let freq = state.frequency;
        let amp = state.amplitude;
        let r = state.color_r;
        let g = state.color_g;
        let b = state.color_b;
        let wt = state.wave_type;

        // Clear background
        ctx.set_fill_style_str("#0a0a1a");
        ctx.fill_rect(0.0, 0.0, w, h);

        // Draw grid lines for visual reference
        ctx.set_stroke_style_str("rgba(255, 255, 255, 0.04)");
        ctx.set_line_width(1.0);
        let grid_spacing = 30.0;
        let mut gy = grid_spacing;
        while gy < h {
            ctx.begin_path();
            ctx.move_to(0.0, gy);
            ctx.line_to(w, gy);
            ctx.stroke();
            gy += grid_spacing;
        }
        let mut gx = grid_spacing;
        while gx < w {
            ctx.begin_path();
            ctx.move_to(gx, 0.0);
            ctx.line_to(gx, h);
            ctx.stroke();
            gx += grid_spacing;
        }

        // Center line
        ctx.set_stroke_style_str("rgba(255, 255, 255, 0.08)");
        ctx.begin_path();
        ctx.move_to(0.0, mid_y);
        ctx.line_to(w, mid_y);
        ctx.stroke();

        // Draw multiple wave layers with slight offsets for depth
        let layer_count = 3;
        for layer in 0..layer_count {
            let layer_f = layer as f64;
            let offset = layer_f * 0.3;
            let alpha = 0.15 + (layer_f / layer_count as f64) * 0.55;
            let layer_amp = amp * (0.6 + layer_f * 0.2);

            let color_str =
                format!("rgba({}, {}, {}, {:.2})", r, g, b, alpha);
            ctx.set_stroke_style_str(&color_str);
            ctx.set_line_width(1.5 + layer_f * 0.5);

            ctx.begin_path();

            let steps = w as usize;
            for i in 0..=steps {
                let x = i as f64;
                let phase = (x / w) * freq * TAU + t + offset;
                let y = mid_y + wave_value(wt, phase) * layer_amp;

                if i == 0 {
                    ctx.move_to(x, y);
                } else {
                    ctx.line_to(x, y);
                }
            }

            ctx.stroke();
        }

        // Main wave (brightest layer)
        let main_color = format!("rgba({}, {}, {}, 0.9)", r, g, b);
        ctx.set_stroke_style_str(&main_color);
        ctx.set_line_width(2.5);

        ctx.begin_path();
        let steps = w as usize;
        for i in 0..=steps {
            let x = i as f64;
            let phase = (x / w) * freq * TAU + t;
            let y = mid_y + wave_value(wt, phase) * amp;

            if i == 0 {
                ctx.move_to(x, y);
            } else {
                ctx.line_to(x, y);
            }
        }
        ctx.stroke();

        // Glow effect on the main wave using a wider, more transparent stroke
        let glow_color = format!("rgba({}, {}, {}, 0.15)", r, g, b);
        ctx.set_stroke_style_str(&glow_color);
        ctx.set_line_width(8.0);

        ctx.begin_path();
        for i in 0..=steps {
            let x = i as f64;
            let phase = (x / w) * freq * TAU + t;
            let y = mid_y + wave_value(wt, phase) * amp;

            if i == 0 {
                ctx.move_to(x, y);
            } else {
                ctx.line_to(x, y);
            }
        }
        ctx.stroke();

        // Particle dots along the main wave
        let particle_count = 20;
        let particle_spacing = w / particle_count as f64;
        for i in 0..particle_count {
            let x = (i as f64 + 0.5) * particle_spacing;
            let phase = (x / w) * freq * TAU + t;
            let y = mid_y + wave_value(wt, phase) * amp;

            // Particle size pulses slightly
            let pulse = ((t * 3.0 + i as f64 * 0.5).sin() * 0.5 + 0.5) * 2.0 + 1.5;

            // Bright center
            let dot_color = format!("rgba({}, {}, {}, 0.9)", r, g, b);
            ctx.set_fill_style_str(&dot_color);
            ctx.begin_path();
            ctx.arc(x, y, pulse, 0.0, TAU).unwrap();
            ctx.fill();

            // Glow around each particle
            let glow = format!("rgba({}, {}, {}, 0.2)", r, g, b);
            ctx.set_fill_style_str(&glow);
            ctx.begin_path();
            ctx.arc(x, y, pulse * 2.5, 0.0, TAU).unwrap();
            ctx.fill();
        }
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

/// Parse a hex color string like "#00d2ff" into (r, g, b).
fn parse_hex_color(hex: &str) -> Option<(u8, u8, u8)> {
    let hex = hex.trim_start_matches('#');
    if hex.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
    let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
    let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
    Some((r, g, b))
}
