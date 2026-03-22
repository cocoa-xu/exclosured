//! Column profiling: summary statistics for numeric columns and top-value
//! frequencies for text columns.

use serde_json::Value;
use std::collections::HashMap;
use wasm_bindgen::prelude::*;

/// Profile a single column: count nulls, unique values, and compute basic
/// stats for numeric columns or top-value frequencies for text columns.
///
/// Input: JSON array of values (can be strings, numbers, or nulls), and a
/// column type hint ("numeric" or "text").
///
/// Output for numeric columns:
/// `{"total":1000,"nulls":5,"unique":847,"min":0.5,"max":99.2,"mean":45.1,"std":28.3}`
///
/// Output for text columns:
/// `{"total":1000,"nulls":2,"unique":150,"top_values":[{"value":"NYC","count":42},{"value":"LA","count":38}]}`
#[wasm_bindgen]
pub fn profile_column(values_json: &str, col_type: &str) -> String {
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

    let total = arr.len();
    let nulls = arr.iter().filter(|v| v.is_null()).count();

    if col_type == "numeric" {
        profile_numeric(arr, total, nulls)
    } else {
        profile_text(arr, total, nulls)
    }
}

/// Profile a numeric column: compute unique count, min, max, mean, std.
fn profile_numeric(arr: &[Value], total: usize, nulls: usize) -> String {
    let values: Vec<f64> = arr.iter().filter_map(|v| v.as_f64()).collect();

    // Count unique values by converting to a string representation.
    let mut unique_set: std::collections::HashSet<String> = std::collections::HashSet::new();
    for v in &values {
        unique_set.insert(format!("{}", v));
    }
    // Also count nulls as a distinct "value" if present.
    let unique = unique_set.len() + if nulls > 0 { 1 } else { 0 };

    if values.is_empty() {
        return format!(
            r#"{{"total":{},"nulls":{},"unique":{},"min":null,"max":null,"mean":null,"std":null}}"#,
            total, nulls, unique,
        );
    }

    let n = values.len() as f64;
    let min = values.iter().cloned().fold(f64::INFINITY, f64::min);
    let max = values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let sum: f64 = values.iter().sum();
    let mean = sum / n;
    let variance: f64 = values.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / n;
    let std = variance.sqrt();

    let round1 = |x: f64| (x * 10.0).round() / 10.0;

    format!(
        r#"{{"total":{},"nulls":{},"unique":{},"min":{},"max":{},"mean":{},"std":{}}}"#,
        total,
        nulls,
        unique,
        round1(min),
        round1(max),
        round1(mean),
        round1(std),
    )
}

/// Profile a text column: compute unique count and top value frequencies.
fn profile_text(arr: &[Value], total: usize, nulls: usize) -> String {
    let mut freq: HashMap<String, usize> = HashMap::new();
    for v in arr {
        if let Some(s) = v.as_str() {
            *freq.entry(s.to_string()).or_insert(0) += 1;
        }
    }

    let unique = freq.len() + if nulls > 0 { 1 } else { 0 };

    // Sort by frequency descending and take top 10.
    let mut entries: Vec<(String, usize)> = freq.into_iter().collect();
    entries.sort_by(|a, b| b.1.cmp(&a.1));
    entries.truncate(10);

    let top_values: Vec<String> = entries
        .iter()
        .map(|(val, count)| {
            // Escape double quotes in the value for valid JSON.
            let escaped = val.replace('\\', "\\\\").replace('"', "\\\"");
            format!(r#"{{"value":"{}","count":{}}}"#, escaped, count)
        })
        .collect();

    format!(
        r#"{{"total":{},"nulls":{},"unique":{},"top_values":[{}]}}"#,
        total,
        nulls,
        unique,
        top_values.join(","),
    )
}
