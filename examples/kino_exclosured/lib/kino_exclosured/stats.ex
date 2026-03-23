defmodule KinoExclosured.Stats do
  @moduledoc """
  Inline WASM module for computing column statistics and histograms.

  The Rust code is compiled to WebAssembly at build time via
  `Exclosured.Inline`. It runs in the browser, operating on JSON
  payloads written into WASM linear memory.

  Exported functions:

    * `compute_stats` - receives a JSON array of numbers, returns
      JSON with count, min, max, mean, median, std_dev, p25, p75
    * `compute_histogram` - receives JSON with values and bin count,
      returns JSON with bin edges, counts, min, and max
  """

  use Exclosured.Inline

  defwasm :compute_stats,
    args: [data: :binary],
    deps: [{"serde", "1", features: ["derive"]}, {"serde_json", "1"}] do
    ~RUST"""
    // Parse JSON array of numbers from the input buffer
    let input_str = core::str::from_utf8(data).unwrap_or("[]");
    let values: Vec<f64> = serde_json::from_str(input_str).unwrap_or_default();

    if values.is_empty() {
        let result = r#"{"count":0,"min":0,"max":0,"mean":0,"median":0,"std_dev":0,"p25":0,"p75":0}"#;
        let result_bytes = result.as_bytes();
        let len = result_bytes.len().min(data.len());
        data[..len].copy_from_slice(&result_bytes[..len]);
        return len as i32;
    }

    let count = values.len() as f64;
    let sum: f64 = values.iter().sum();
    let mean = sum / count;

    let mut sorted = values.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(core::cmp::Ordering::Equal));

    let min_val = sorted[0];
    let max_val = sorted[sorted.len() - 1];

    let median = if sorted.len() % 2 == 0 {
        (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
    } else {
        sorted[sorted.len() / 2]
    };

    let variance: f64 = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / count;
    let std_dev = variance.sqrt();

    let p25_idx = ((sorted.len() as f64) * 0.25) as usize;
    let p75_idx = ((sorted.len() as f64) * 0.75) as usize;
    let p25 = sorted[p25_idx.min(sorted.len() - 1)];
    let p75 = sorted[p75_idx.min(sorted.len() - 1)];

    let result = format!(
        r#"{{"count":{},"min":{},"max":{},"mean":{},"median":{},"std_dev":{},"p25":{},"p75":{}}}"#,
        sorted.len(), min_val, max_val, mean, median, std_dev, p25, p75
    );
    let result_bytes = result.as_bytes();
    let len = result_bytes.len().min(data.len());
    data[..len].copy_from_slice(&result_bytes[..len]);
    len as i32
    """
  end

  defwasm :compute_histogram,
    args: [data: :binary],
    deps: [{"serde", "1", features: ["derive"]}, {"serde_json", "1"}] do
    ~RUST"""
    // Parse JSON: {"values": [...], "bins": 20}
    #[derive(serde::Deserialize)]
    struct HistInput { values: Vec<f64>, bins: usize }

    let input_str = core::str::from_utf8(data).unwrap_or("{}");
    let input: HistInput = match serde_json::from_str(input_str) {
        Ok(v) => v,
        Err(_) => {
            let err = r#"{"error":"invalid input"}"#;
            let err_bytes = err.as_bytes();
            let len = err_bytes.len().min(data.len());
            data[..len].copy_from_slice(&err_bytes[..len]);
            return len as i32;
        }
    };

    let values = input.values;
    let num_bins = if input.bins == 0 { 20 } else { input.bins };

    if values.is_empty() {
        let empty = r#"{"bins":[],"counts":[],"min":0,"max":0}"#;
        let empty_bytes = empty.as_bytes();
        let len = empty_bytes.len().min(data.len());
        data[..len].copy_from_slice(&empty_bytes[..len]);
        return len as i32;
    }

    let min_val = values.iter().cloned().fold(f64::INFINITY, f64::min);
    let max_val = values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

    let range = max_val - min_val;
    let bin_width = if range == 0.0 { 1.0 } else { range / num_bins as f64 };

    let mut counts = vec![0u64; num_bins];
    for &v in &values {
        let idx = ((v - min_val) / bin_width) as usize;
        let idx = idx.min(num_bins - 1);
        counts[idx] += 1;
    }

    // Build bin edges
    let bin_edges: Vec<f64> = (0..=num_bins).map(|i| min_val + i as f64 * bin_width).collect();

    let bins_json: Vec<String> = bin_edges.iter().map(|v| format!("{}", v)).collect();
    let counts_json: Vec<String> = counts.iter().map(|c| format!("{}", c)).collect();

    let result = format!(
        r#"{{"bins":[{}],"counts":[{}],"min":{},"max":{}}}"#,
        bins_json.join(","),
        counts_json.join(","),
        min_val,
        max_val
    );
    let result_bytes = result.as_bytes();
    let len = result_bytes.len().min(data.len());
    data[..len].copy_from_slice(&result_bytes[..len]);
    len as i32
    """
  end
end
