//! Histogram computation and canvas rendering.
//!
//! Provides a pure computation function (`compute_histogram`) that bins numeric
//! data and a canvas-drawing function (`draw_histogram`) that renders the
//! histogram directly onto an `HtmlCanvasElement` via the Canvas 2D API.

use serde_json::Value;
use wasm_bindgen::prelude::*;

/// Compute a histogram for a numeric column from the result data.
///
/// Input: JSON string of column values (array of numbers or nulls), and the
/// desired number of bins.
///
/// Output: JSON string with bin edges, counts, and summary statistics.
/// Example: `{"bins":[0,10,20,30],"counts":[5,12,8],"min":0.5,"max":29.7,"mean":15.3,"std":8.2}`
#[wasm_bindgen]
pub fn compute_histogram(values_json: &str, num_bins: u32) -> String {
    let parsed: Value = match serde_json::from_str(values_json) {
        Ok(v) => v,
        Err(e) => {
            return format!(r#"{{"error":"failed to parse JSON: {}"}}"#, e);
        }
    };

    let arr = match parsed.as_array() {
        Some(a) => a,
        None => {
            return r#"{"error":"input must be a JSON array"}"#.to_string();
        }
    };

    // Extract numeric values, filtering out nulls and non-numbers.
    let values: Vec<f64> = arr
        .iter()
        .filter_map(|v| v.as_f64())
        .collect();

    if values.is_empty() {
        return r#"{"bins":[],"counts":[],"min":null,"max":null,"mean":null,"std":null}"#.to_string();
    }

    let n = values.len() as f64;
    let min = values.iter().cloned().fold(f64::INFINITY, f64::min);
    let max = values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let sum: f64 = values.iter().sum();
    let mean = sum / n;
    let variance: f64 = values.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / n;
    let std = variance.sqrt();

    let num_bins = if num_bins == 0 { 1 } else { num_bins as usize };

    // Build equally spaced bin edges.
    let range = max - min;
    let bin_width = if range == 0.0 {
        1.0
    } else {
        range / num_bins as f64
    };

    let mut bins: Vec<f64> = Vec::with_capacity(num_bins + 1);
    for i in 0..=num_bins {
        bins.push(min + bin_width * i as f64);
    }

    // Count values per bin.
    let mut counts: Vec<u64> = vec![0; num_bins];
    for v in &values {
        let mut idx = ((v - min) / bin_width) as usize;
        // Values equal to max go into the last bin.
        if idx >= num_bins {
            idx = num_bins - 1;
        }
        counts[idx] += 1;
    }

    // Round statistics to one decimal place for readability.
    let round1 = |x: f64| (x * 10.0).round() / 10.0;

    let bins_json: Vec<String> = bins.iter().map(|b| format!("{}", round1(*b))).collect();
    let counts_json: Vec<String> = counts.iter().map(|c| c.to_string()).collect();

    format!(
        r#"{{"bins":[{}],"counts":[{}],"min":{},"max":{},"mean":{},"std":{}}}"#,
        bins_json.join(","),
        counts_json.join(","),
        round1(min),
        round1(max),
        round1(mean),
        round1(std),
    )
}

/// Draw a histogram on a canvas element.
/// Takes the histogram JSON (from compute_histogram) and a canvas element.
/// `theme` should be "light" or "dark".
#[wasm_bindgen]
pub fn draw_histogram(canvas: web_sys::HtmlCanvasElement, hist_json: &str, theme: &str) {
    let parsed: Value = match serde_json::from_str(hist_json) {
        Ok(v) => v,
        Err(_) => return,
    };

    let bins = match parsed.get("bins").and_then(|v| v.as_array()) {
        Some(b) => b,
        None => return,
    };
    let counts = match parsed.get("counts").and_then(|v| v.as_array()) {
        Some(c) => c,
        None => return,
    };

    if counts.is_empty() || bins.len() < 2 {
        return;
    }

    let ctx = match canvas
        .get_context("2d")
        .ok()
        .flatten()
    {
        Some(ctx) => ctx.dyn_into::<web_sys::CanvasRenderingContext2d>().unwrap(),
        None => return,
    };

    let width = canvas.width() as f64;
    let height = canvas.height() as f64;

    // Theme colors
    let (bg_color, bar_color, text_color, grid_color) = if theme == "dark" {
        ("#1e1e2e", "#7c3aed", "#e2e8f0", "#334155")
    } else {
        ("#ffffff", "#6366f1", "#1e293b", "#e2e8f0")
    };

    // Clear canvas
    ctx.set_fill_style_str(bg_color);
    ctx.fill_rect(0.0, 0.0, width, height);

    // Margins
    let margin_left = 50.0;
    let margin_right = 20.0;
    let margin_top = 20.0;
    let margin_bottom = 40.0;

    let chart_width = width - margin_left - margin_right;
    let chart_height = height - margin_top - margin_bottom;

    let count_values: Vec<f64> = counts
        .iter()
        .filter_map(|v| v.as_f64())
        .collect();

    let max_count = count_values.iter().cloned().fold(0.0_f64, f64::max);
    if max_count == 0.0 {
        return;
    }

    let num_bars = count_values.len();
    let bar_width = chart_width / num_bars as f64;
    let gap = (bar_width * 0.1).max(1.0);

    // Draw grid lines
    ctx.set_stroke_style_str(grid_color);
    ctx.set_line_width(0.5);
    let grid_lines = 4;
    for i in 0..=grid_lines {
        let y = margin_top + chart_height * (1.0 - i as f64 / grid_lines as f64);
        ctx.begin_path();
        ctx.move_to(margin_left, y);
        ctx.line_to(width - margin_right, y);
        ctx.stroke();

        // Y-axis label
        let label_val = max_count * i as f64 / grid_lines as f64;
        ctx.set_fill_style_str(text_color);
        ctx.set_font("11px sans-serif");
        ctx.set_text_align("right");
        let _ = ctx.fill_text(&format!("{}", label_val as u64), margin_left - 5.0, y + 4.0);
    }

    // Draw bars
    ctx.set_fill_style_str(bar_color);
    for (i, count) in count_values.iter().enumerate() {
        let bar_h = (count / max_count) * chart_height;
        let x = margin_left + i as f64 * bar_width + gap / 2.0;
        let y = margin_top + chart_height - bar_h;
        ctx.fill_rect(x, y, bar_width - gap, bar_h);
    }

    // Draw x-axis labels (bin edges)
    ctx.set_fill_style_str(text_color);
    ctx.set_font("10px sans-serif");
    ctx.set_text_align("center");

    let bin_values: Vec<f64> = bins.iter().filter_map(|v| v.as_f64()).collect();
    let label_step = if num_bars > 10 { num_bars / 5 } else { 1 };

    for (i, bin_val) in bin_values.iter().enumerate() {
        if i % label_step != 0 && i != bin_values.len() - 1 {
            continue;
        }
        let x = margin_left + i as f64 * bar_width;
        let y = height - margin_bottom + 15.0;
        let label = format!("{:.1}", bin_val);
        let _ = ctx.fill_text(&label, x, y);
    }
}
