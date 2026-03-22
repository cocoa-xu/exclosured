//! Private Analytics WASM module.
//!
//! This WASM module provides three categories of functionality for the
//! Private Analytics demo:
//!
//! 1. **Crypto**: E2E encryption and decryption using AES-256-GCM. Data from
//!    DuckDB queries is encrypted before being sent to the server, and
//!    decrypted on the receiving end. The encryption key never leaves the
//!    browser.
//!
//! 2. **PII masking**: Scans JSON row data for personally identifiable
//!    information (emails, phone numbers, SSNs, credit card numbers) and
//!    replaces them with masked values.
//!
//! 3. **Data profiling and histograms**: Computes summary statistics, null
//!    counts, unique values, and bin-based histograms for numeric and text
//!    columns.

use wasm_bindgen::prelude::*;
use aes_gcm::aead::rand_core::RngCore;
use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

// Re-export alloc/dealloc from exclosured_guest for JS interop memory management.
pub use exclosured_guest::{alloc, dealloc};

/// Generate a new 256-bit AES key. Returns a base64-encoded key.
#[wasm_bindgen]
pub fn generate_key() -> String {
    let mut key_bytes = [0u8; 32];
    OsRng.fill_bytes(&mut key_bytes);
    BASE64.encode(key_bytes)
}

/// Generate a random token (128-bit). Returns a base64-encoded token.
#[wasm_bindgen]
pub fn generate_token() -> String {
    let mut token_bytes = [0u8; 16];
    OsRng.fill_bytes(&mut token_bytes);
    BASE64.encode(token_bytes)
}

/// Compute SHA-256 hash of a base64-encoded token. Returns a hex-encoded hash.
///
/// The hash is sent to the server for role verification, while the original
/// token remains secret in the browser.
#[wasm_bindgen]
pub fn hash_token(token_b64: &str) -> Result<String, JsValue> {
    let token_bytes = BASE64
        .decode(token_b64)
        .map_err(|e| JsValue::from_str(&format!("invalid base64 token: {}", e)))?;

    let mut hasher = Sha256::new();
    hasher.update(&token_bytes);
    let hash = hasher.finalize();

    Ok(hex_encode(&hash))
}

/// Encrypt plaintext with the room key. Returns base64-encoded ciphertext.
///
/// The output format is `base64(nonce || ciphertext)` where the nonce is a
/// fresh random 96-bit value generated for each call.
#[wasm_bindgen]
pub fn encrypt(key_b64: &str, plaintext: &str) -> Result<String, JsValue> {
    let key_bytes = BASE64
        .decode(key_b64)
        .map_err(|e| JsValue::from_str(&format!("invalid base64 key: {}", e)))?;

    if key_bytes.len() != 32 {
        return Err(JsValue::from_str("key must be exactly 32 bytes (AES-256)"));
    }

    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher =
        Aes256Gcm::new(key);

    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| JsValue::from_str(&format!("encryption failed: {}", e)))?;

    // Prepend nonce to ciphertext: nonce (12 bytes) || ciphertext
    let mut combined = Vec::with_capacity(12 + ciphertext.len());
    combined.extend_from_slice(&nonce_bytes);
    combined.extend_from_slice(&ciphertext);

    Ok(BASE64.encode(combined))
}

/// Decrypt ciphertext with the room key. Returns the plaintext string.
///
/// The input format is `base64(nonce || ciphertext)` as produced by `encrypt`.
#[wasm_bindgen]
pub fn decrypt(key_b64: &str, ciphertext_b64: &str) -> Result<String, JsValue> {
    let key_bytes = BASE64
        .decode(key_b64)
        .map_err(|e| JsValue::from_str(&format!("invalid base64 key: {}", e)))?;

    if key_bytes.len() != 32 {
        return Err(JsValue::from_str("key must be exactly 32 bytes (AES-256)"));
    }

    let combined = BASE64
        .decode(ciphertext_b64)
        .map_err(|e| JsValue::from_str(&format!("invalid base64 ciphertext: {}", e)))?;

    if combined.len() < 12 {
        return Err(JsValue::from_str(
            "ciphertext too short, must contain at least a 12-byte nonce",
        ));
    }

    let (nonce_bytes, ciphertext) = combined.split_at(12);
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext_bytes = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| JsValue::from_str(&format!("decryption failed: {}", e)))?;

    String::from_utf8(plaintext_bytes)
        .map_err(|e| JsValue::from_str(&format!("decrypted data is not valid UTF-8: {}", e)))
}

/// Build a share URL fragment containing the room key and role token.
///
/// The output format is `base64(key) + "." + base64(token)`, suitable for
/// placing in the URL fragment (after the `#`).
#[wasm_bindgen]
pub fn build_share_fragment(key_b64: &str, token_b64: &str) -> String {
    format!("{}.{}", key_b64, token_b64)
}

/// Parse a share URL fragment. Returns a JSON string with `key` and `token` fields.
///
/// The input format is `base64(key) + "." + base64(token)` as produced by
/// `build_share_fragment`. The returned JSON looks like:
/// `{"key":"<base64key>","token":"<base64token>"}`.
#[wasm_bindgen]
pub fn parse_share_fragment(fragment: &str) -> Result<String, JsValue> {
    let parts: Vec<&str> = fragment.splitn(2, '.').collect();
    if parts.len() != 2 {
        return Err(JsValue::from_str(
            "invalid fragment format, expected base64key.base64token",
        ));
    }

    let key_b64 = parts[0];
    let token_b64 = parts[1];

    // Validate that both parts are valid base64.
    BASE64
        .decode(key_b64)
        .map_err(|e| JsValue::from_str(&format!("invalid base64 key in fragment: {}", e)))?;
    BASE64
        .decode(token_b64)
        .map_err(|e| JsValue::from_str(&format!("invalid base64 token in fragment: {}", e)))?;

    Ok(format!(
        r#"{{"key":"{}","token":"{}"}}"#,
        key_b64, token_b64
    ))
}

/// Encode bytes as a lowercase hex string.
fn hex_encode(bytes: &[u8]) -> String {
    let mut hex = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        hex.push_str(&format!("{:02x}", b));
    }
    hex
}

// ---------------------------------------------------------------------------
// PII masking
// ---------------------------------------------------------------------------

/// Scan a JSON string of rows and mask PII patterns.
///
/// Input: JSON string like
/// `{"columns":["name","email","phone"],"rows":[{"name":"John","email":"john@example.com","phone":"555-123-4567"}]}`
///
/// Output: Same structure with PII values masked.
///
/// Patterns detected and masked:
///   - Email addresses: `john@example.com` -> `j***@e***.com`
///   - Phone numbers (digits with dashes/spaces/parens, 10+ digits): `555-123-4567` -> `***-***-4567`
///   - SSN patterns (XXX-XX-XXXX): `123-45-6789` -> `***-**-6789`
///   - Credit card numbers (13-19 consecutive digits): `4111111111111111` -> `************1111`
#[wasm_bindgen]
pub fn mask_pii(json_data: &str) -> String {
    let parsed: Value = match serde_json::from_str(json_data) {
        Ok(v) => v,
        Err(e) => {
            return format!(r#"{{"error":"failed to parse JSON: {}"}}"#, e);
        }
    };

    let masked = mask_value(&parsed);
    serde_json::to_string(&masked).unwrap_or_else(|e| {
        format!(r#"{{"error":"failed to serialize JSON: {}"}}"#, e)
    })
}

/// Recursively walk a JSON value and mask PII in any string leaf.
fn mask_value(val: &Value) -> Value {
    match val {
        Value::String(s) => Value::String(mask_string(s)),
        Value::Array(arr) => Value::Array(arr.iter().map(mask_value).collect()),
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, v) in map {
                out.insert(k.clone(), mask_value(v));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

/// Apply PII masking rules to a single string value.
/// Checks patterns in order of specificity: SSN, credit card, email, phone.
fn mask_string(s: &str) -> String {
    // SSN: exactly NNN-NN-NNNN
    if is_ssn(s) {
        return mask_ssn(s);
    }

    // Credit card: 13-19 consecutive digits (possibly with spaces or dashes)
    if is_credit_card(s) {
        return mask_credit_card(s);
    }

    // Email: contains @ with valid local and domain parts
    if is_email(s) {
        return mask_email(s);
    }

    // Phone: digits (with optional separators), at least 10 digits total
    if is_phone(s) {
        return mask_phone(s);
    }

    s.to_string()
}

/// Check if the string matches SSN pattern: 3 digits, dash, 2 digits, dash, 4 digits.
fn is_ssn(s: &str) -> bool {
    let trimmed = s.trim();
    let chars: Vec<char> = trimmed.chars().collect();
    if chars.len() != 11 {
        return false;
    }
    chars[0].is_ascii_digit()
        && chars[1].is_ascii_digit()
        && chars[2].is_ascii_digit()
        && chars[3] == '-'
        && chars[4].is_ascii_digit()
        && chars[5].is_ascii_digit()
        && chars[6] == '-'
        && chars[7].is_ascii_digit()
        && chars[8].is_ascii_digit()
        && chars[9].is_ascii_digit()
        && chars[10].is_ascii_digit()
}

/// Mask SSN: `123-45-6789` -> `***-**-6789`
fn mask_ssn(s: &str) -> String {
    let trimmed = s.trim();
    let last_four = &trimmed[7..11];
    format!("***-**-{}", last_four)
}

/// Check if the string looks like a credit card number (13-19 digits, possibly
/// separated by spaces or dashes).
fn is_credit_card(s: &str) -> bool {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return false;
    }
    // All characters must be digits, spaces, or dashes.
    if !trimmed.chars().all(|c| c.is_ascii_digit() || c == ' ' || c == '-') {
        return false;
    }
    let digit_count = trimmed.chars().filter(|c| c.is_ascii_digit()).count();
    (13..=19).contains(&digit_count)
}

/// Mask credit card: keep the last 4 digits, replace the rest with `*`.
fn mask_credit_card(s: &str) -> String {
    let trimmed = s.trim();
    let digits: Vec<char> = trimmed.chars().filter(|c| c.is_ascii_digit()).collect();
    let total = digits.len();
    if total < 4 {
        return s.to_string();
    }
    let masked_count = total - 4;
    let last_four: String = digits[masked_count..].iter().collect();
    let stars: String = std::iter::repeat('*').take(masked_count).collect();
    format!("{}{}", stars, last_four)
}

/// Check if the string is an email address: contains `@` with alphanumeric
/// characters on both sides, and a dot in the domain part.
fn is_email(s: &str) -> bool {
    let trimmed = s.trim();
    let parts: Vec<&str> = trimmed.splitn(2, '@').collect();
    if parts.len() != 2 {
        return false;
    }
    let local = parts[0];
    let domain = parts[1];
    if local.is_empty() || domain.is_empty() {
        return false;
    }
    // Domain must contain at least one dot.
    if !domain.contains('.') {
        return false;
    }
    // Local part: allow alphanumeric, dots, underscores, hyphens, plus.
    let valid_local = local
        .chars()
        .all(|c| c.is_alphanumeric() || c == '.' || c == '_' || c == '-' || c == '+');
    // Domain: allow alphanumeric, dots, hyphens.
    let valid_domain = domain
        .chars()
        .all(|c| c.is_alphanumeric() || c == '.' || c == '-');
    valid_local && valid_domain
}

/// Mask email: `john@example.com` -> `j***@e***.com`
fn mask_email(s: &str) -> String {
    let trimmed = s.trim();
    let parts: Vec<&str> = trimmed.splitn(2, '@').collect();
    if parts.len() != 2 {
        return s.to_string();
    }
    let local = parts[0];
    let domain = parts[1];

    // Mask local part: keep first character, replace rest with ***
    let masked_local = if local.len() <= 1 {
        local.to_string()
    } else {
        let first: String = local.chars().take(1).collect();
        format!("{}***", first)
    };

    // Mask domain: keep first char and TLD (last dot segment), mask the middle.
    let masked_domain = if let Some(dot_pos) = domain.rfind('.') {
        let domain_name = &domain[..dot_pos];
        let tld = &domain[dot_pos..]; // includes the dot
        let first_char: String = domain_name.chars().take(1).collect();
        format!("{}***{}", first_char, tld)
    } else {
        domain.to_string()
    };

    format!("{}@{}", masked_local, masked_domain)
}

/// Check if the string looks like a phone number: contains at least 10 digits
/// with optional separators (dashes, spaces, parentheses, dots, plus sign).
fn is_phone(s: &str) -> bool {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return false;
    }
    // Must have at least one digit.
    if !trimmed.chars().any(|c| c.is_ascii_digit()) {
        return false;
    }
    // All characters must be digits or phone separators.
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_digit() || c == '-' || c == ' ' || c == '(' || c == ')' || c == '.' || c == '+')
    {
        return false;
    }
    let digit_count = trimmed.chars().filter(|c| c.is_ascii_digit()).count();
    digit_count >= 10
}

/// Mask phone: keep the last 4 digits visible, mask the rest.
/// Preserves separator characters in their original positions.
/// Example: `555-123-4567` -> `***-***-4567`
fn mask_phone(s: &str) -> String {
    let trimmed = s.trim();
    let digits: Vec<char> = trimmed.chars().filter(|c| c.is_ascii_digit()).collect();
    let total_digits = digits.len();
    if total_digits < 4 {
        return s.to_string();
    }
    let visible_start = total_digits - 4;

    let mut digit_index = 0;
    let mut result = String::with_capacity(trimmed.len());
    for c in trimmed.chars() {
        if c.is_ascii_digit() {
            if digit_index < visible_start {
                result.push('*');
            } else {
                result.push(c);
            }
            digit_index += 1;
        } else {
            result.push(c);
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Histogram computation
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Column profiling
// ---------------------------------------------------------------------------

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
