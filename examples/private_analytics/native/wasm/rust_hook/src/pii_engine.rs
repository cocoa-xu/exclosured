//! PII (Personally Identifiable Information) detection and masking engine.
//!
//! Scans JSON row data for common PII patterns (emails, phone numbers, SSNs,
//! credit card numbers) and replaces them with masked values. Also provides
//! column-level PII detection and single-value masking utilities.

use serde_json::Value;
use wasm_bindgen::prelude::*;

// ---------------------------------------------------------------------------
// Public wasm_bindgen exports
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

    let masked = walk_and_mask(&parsed);
    serde_json::to_string(&masked).unwrap_or_else(|e| {
        format!(r#"{{"error":"failed to serialize JSON: {}"}}"#, e)
    })
}

/// Mask a single value generically (for selected-column masking).
/// Known PII patterns get smart masking, everything else gets "******".
#[wasm_bindgen]
pub fn mask_value(val: &str) -> String {
    let masked = mask_string_value(val);
    // If no PII pattern matched, the string comes back unchanged.
    // In that case, apply a generic mask so callers can always expect masking.
    if masked == val {
        "******".to_string()
    } else {
        masked
    }
}

/// Detect which columns likely contain PII by scanning sample rows.
/// Input: JSON string with `columns` (array of column names) and `rows`
/// (array of row objects).
/// Returns: JSON array of column names that contain PII patterns.
#[wasm_bindgen]
pub fn detect_pii_columns(data_json: &str) -> String {
    let parsed: Value = match serde_json::from_str(data_json) {
        Ok(v) => v,
        Err(e) => {
            return format!(r#"{{"error":"failed to parse JSON: {}"}}"#, e);
        }
    };

    let columns = match parsed.get("columns").and_then(|v| v.as_array()) {
        Some(c) => c,
        None => return "[]".to_string(),
    };

    let rows = match parsed.get("rows").and_then(|v| v.as_array()) {
        Some(r) => r,
        None => return "[]".to_string(),
    };

    let mut pii_columns: Vec<String> = Vec::new();

    for col_val in columns {
        let col_name = match col_val.as_str() {
            Some(s) => s,
            None => continue,
        };

        // Sample up to 50 rows for each column
        let sample_size = rows.len().min(50);
        let mut pii_hits = 0usize;
        let mut checked = 0usize;

        for row in rows.iter().take(sample_size) {
            if let Some(val) = row.get(col_name).and_then(|v| v.as_str()) {
                checked += 1;
                if is_email(val) || is_phone(val) || is_ssn(val) || is_credit_card(val) {
                    pii_hits += 1;
                }
            }
        }

        // If more than 20% of non-null sampled values look like PII, flag the column
        if checked > 0 && pii_hits * 5 >= checked {
            pii_columns.push(col_name.to_string());
        }
    }

    serde_json::to_string(&pii_columns).unwrap_or_else(|_| "[]".to_string())
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Recursively walk a JSON value and mask PII in any string leaf.
pub fn walk_and_mask(val: &Value) -> Value {
    match val {
        Value::String(s) => Value::String(mask_string_value(s)),
        Value::Array(arr) => Value::Array(arr.iter().map(walk_and_mask).collect()),
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, v) in map {
                out.insert(k.clone(), walk_and_mask(v));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

/// Apply PII masking rules to a single string value.
/// Checks patterns in order of specificity: SSN, credit card, email, phone.
pub fn mask_string_value(s: &str) -> String {
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
pub fn is_ssn(s: &str) -> bool {
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
pub fn mask_ssn(s: &str) -> String {
    let trimmed = s.trim();
    let last_four = &trimmed[7..11];
    format!("***-**-{}", last_four)
}

/// Check if the string looks like a credit card number (13-19 digits, possibly
/// separated by spaces or dashes).
pub fn is_credit_card(s: &str) -> bool {
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
pub fn mask_credit_card(s: &str) -> String {
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
pub fn is_email(s: &str) -> bool {
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
pub fn mask_email(s: &str) -> String {
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
pub fn is_phone(s: &str) -> bool {
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
pub fn mask_phone(s: &str) -> String {
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
