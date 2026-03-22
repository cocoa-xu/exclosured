//! Private Analytics WASM module: cryptographic operations.
//!
//! Provides E2E encryption and decryption using AES-256-GCM. Data from
//! DuckDB queries is encrypted before being sent to the server, and
//! decrypted on the receiving end. The encryption key never leaves the
//! browser.

use wasm_bindgen::prelude::*;
use aes_gcm::aead::rand_core::RngCore;
use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use sha2::{Digest, Sha256};

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
