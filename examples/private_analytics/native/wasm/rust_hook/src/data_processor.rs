//! Data normalization utilities.
//!
//! Handles BigInt-style values, null coercion, and other value conversions to
//! ensure query results are always JSON-serializable.

use serde_json::Value;
use wasm_bindgen::prelude::*;

/// Normalize a JSON array of query result rows.
/// Converts BigInt-style values, handles nulls, ensures JSON-serializable output.
///
/// Rules applied to each value:
///   - If a value is a JSON object with a single `"$bigint"` key, replace it
///     with the string representation of that number.
///   - `undefined` strings become JSON null.
///   - All other values pass through unchanged.
///
/// Returns the normalized JSON string.
#[wasm_bindgen]
pub fn normalize_rows(json: &str) -> String {
    let parsed: Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(e) => {
            return format!(r#"{{"error":"failed to parse JSON: {}"}}"#, e);
        }
    };

    let normalized = normalize_value(&parsed);
    serde_json::to_string(&normalized).unwrap_or_else(|e| {
        format!(r#"{{"error":"failed to serialize JSON: {}"}}"#, e)
    })
}

/// Recursively normalize a single JSON value.
pub fn normalize_value(val: &Value) -> Value {
    match val {
        Value::Object(map) => {
            // BigInt pattern: {"$bigint": "123456789012345"}
            if map.len() == 1 {
                if let Some(bigint_val) = map.get("$bigint") {
                    return match bigint_val {
                        Value::String(s) => Value::String(s.clone()),
                        Value::Number(n) => Value::String(n.to_string()),
                        _ => val.clone(),
                    };
                }
            }

            // Recurse into object fields
            let mut out = serde_json::Map::new();
            for (k, v) in map {
                out.insert(k.clone(), normalize_value(v));
            }
            Value::Object(out)
        }
        Value::Array(arr) => {
            Value::Array(arr.iter().map(normalize_value).collect())
        }
        Value::String(s) if s == "undefined" => Value::Null,
        other => other.clone(),
    }
}
