use wasm_bindgen::prelude::*;

/// exclosured:rpc
#[wasm_bindgen]
pub fn score(input: String, factor: f64) -> f64 {
    input.len() as f64 * factor
}

/// exclosured:rpc
#[wasm_bindgen]
pub fn tokenize(
    text: &str,
    limit: Option<u32>,
) -> Vec<String> {
    text.split_whitespace()
        .take(limit.unwrap_or(u32::MAX) as usize)
        .map(str::to_string)
        .collect()
}

/// exclosured:rpc
#[wasm_bindgen]
pub fn digest(data: &[u8]) -> u32 {
    data.iter().fold(0, |acc, byte| acc + *byte as u32)
}

/// exclosured:rpc
#[wasm_bindgen]
pub fn version() -> String {
    "1.0.0".to_string()
}

/// exclosured:rpc
#[wasm_bindgen]
pub async fn fetch_score(input: String) -> u32 {
    input.len() as u32
}

#[wasm_bindgen]
pub fn internal(value: u32) -> u32 {
    value
}
