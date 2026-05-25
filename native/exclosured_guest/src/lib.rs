//! Exclosured guest-side helpers for WASM modules.
//!
//! Provides `emit()` for sending events to LiveView, `broadcast()` for
//! inter-module communication, and memory management exports (`alloc`/`dealloc`).

use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = __exclosured)]
    fn emit_event(event: &str, payload: &str);
    #[wasm_bindgen(js_namespace = __exclosured)]
    fn broadcast_event(channel: &str, data: &str);
}

/// Emit an event to the LiveView server.
///
/// The event name and JSON payload are sent through the JS hook
/// and arrive as a `{:wasm_emit, module, event, payload}` message
/// in the LiveView process.
///
/// # Example
///
/// ```rust,no_run
/// exclosured_guest::emit("progress", r#"{"percent": 50}"#);
/// ```
pub fn emit(event: &str, payload: &str) {
    emit_event(event, payload);
}

/// Broadcast a message to other WASM modules on the same page.
///
/// This does NOT go through the server. The message is dispatched
/// via the client-side JS event bus to other modules that have
/// subscribed to the given channel.
///
/// # Example
///
/// ```rust,no_run
/// exclosured_guest::broadcast("ai:result", r#"{"label": "cat"}"#);
/// ```
pub fn broadcast(channel: &str, data: &str) {
    broadcast_event(channel, data);
}

/// Decoder for `Exclosured.Protocol` binary state payloads.
pub mod protocol {
    use core::fmt;

    const TAG_INT: u8 = 0x01;
    const TAG_FLOAT: u8 = 0x02;
    const TAG_STRING: u8 = 0x03;
    const TAG_BINARY: u8 = 0x04;
    const TAG_LIST: u8 = 0x05;
    const TAG_MAP: u8 = 0x06;
    const TAG_BOOL: u8 = 0x07;
    const TAG_NIL: u8 = 0x08;
    const TAG_ATOM: u8 = 0x09;

    /// A decoded Exclosured protocol value.
    #[derive(Clone, Debug, PartialEq)]
    pub enum Value {
        Integer(i64),
        Float(f64),
        String(String),
        Binary(Vec<u8>),
        List(Vec<Value>),
        Map(Vec<(Value, Value)>),
        Bool(bool),
        Nil,
        Atom(String),
    }

    /// A protocol decode error.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum DecodeError {
        InvalidBool(u8),
        InvalidUtf8,
        TrailingBytes(usize),
        UnexpectedEof,
        UnknownTag(u8),
    }

    impl fmt::Display for DecodeError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            match self {
                DecodeError::InvalidBool(value) => {
                    write!(f, "invalid boolean value {value}")
                }
                DecodeError::InvalidUtf8 => f.write_str("invalid UTF-8 string"),
                DecodeError::TrailingBytes(count) => {
                    write!(f, "{count} trailing bytes after protocol value")
                }
                DecodeError::UnexpectedEof => f.write_str("unexpected end of protocol payload"),
                DecodeError::UnknownTag(tag) => write!(f, "unknown protocol tag 0x{tag:02x}"),
            }
        }
    }

    impl std::error::Error for DecodeError {}

    /// Decode one complete `Exclosured.Protocol` payload.
    pub fn decode(input: &[u8]) -> Result<Value, DecodeError> {
        let (value, rest) = decode_value(input)?;

        if rest.is_empty() {
            Ok(value)
        } else {
            Err(DecodeError::TrailingBytes(rest.len()))
        }
    }

    fn decode_value(input: &[u8]) -> Result<(Value, &[u8]), DecodeError> {
        let (&tag, rest) = input.split_first().ok_or(DecodeError::UnexpectedEof)?;

        match tag {
            TAG_INT => {
                let (bytes, rest) = take(rest, 8)?;
                Ok((
                    Value::Integer(i64::from_be_bytes(bytes.try_into().unwrap())),
                    rest,
                ))
            }
            TAG_FLOAT => {
                let (bytes, rest) = take(rest, 8)?;
                Ok((
                    Value::Float(f64::from_bits(u64::from_be_bytes(
                        bytes.try_into().unwrap(),
                    ))),
                    rest,
                ))
            }
            TAG_STRING => decode_string(rest).map(|(value, rest)| (Value::String(value), rest)),
            TAG_BINARY => {
                let (bytes, rest) = decode_bytes(rest)?;
                Ok((Value::Binary(bytes.to_vec()), rest))
            }
            TAG_LIST => decode_list(rest),
            TAG_MAP => decode_map(rest),
            TAG_BOOL => {
                let (&value, rest) = rest.split_first().ok_or(DecodeError::UnexpectedEof)?;

                match value {
                    0 => Ok((Value::Bool(false), rest)),
                    1 => Ok((Value::Bool(true), rest)),
                    other => Err(DecodeError::InvalidBool(other)),
                }
            }
            TAG_NIL => Ok((Value::Nil, rest)),
            TAG_ATOM => decode_string(rest).map(|(value, rest)| (Value::Atom(value), rest)),
            other => Err(DecodeError::UnknownTag(other)),
        }
    }

    fn decode_list(input: &[u8]) -> Result<(Value, &[u8]), DecodeError> {
        let (count, mut rest) = decode_len(input)?;
        let mut values = Vec::new();

        for _ in 0..count {
            let (value, next) = decode_value(rest)?;
            values.push(value);
            rest = next;
        }

        Ok((Value::List(values), rest))
    }

    fn decode_map(input: &[u8]) -> Result<(Value, &[u8]), DecodeError> {
        let (count, mut rest) = decode_len(input)?;
        let mut pairs = Vec::new();

        for _ in 0..count {
            let (key, next) = decode_value(rest)?;
            let (value, next) = decode_value(next)?;
            pairs.push((key, value));
            rest = next;
        }

        Ok((Value::Map(pairs), rest))
    }

    fn decode_string(input: &[u8]) -> Result<(String, &[u8]), DecodeError> {
        let (bytes, rest) = decode_bytes(input)?;
        let value = core::str::from_utf8(bytes).map_err(|_| DecodeError::InvalidUtf8)?;
        Ok((value.to_owned(), rest))
    }

    fn decode_bytes(input: &[u8]) -> Result<(&[u8], &[u8]), DecodeError> {
        let (len, rest) = decode_len(input)?;
        take(rest, len)
    }

    fn decode_len(input: &[u8]) -> Result<(usize, &[u8]), DecodeError> {
        let (bytes, rest) = take(input, 4)?;
        Ok((u32::from_be_bytes(bytes.try_into().unwrap()) as usize, rest))
    }

    fn take(input: &[u8], count: usize) -> Result<(&[u8], &[u8]), DecodeError> {
        if input.len() < count {
            return Err(DecodeError::UnexpectedEof);
        }

        Ok(input.split_at(count))
    }

    #[cfg(test)]
    mod tests {
        use super::{decode, DecodeError, Value};

        #[test]
        fn decodes_nested_payload() {
            let payload = [
                vec![0x06, 0, 0, 0, 2],
                encode_string("count"),
                vec![0x01, 0, 0, 0, 0, 0, 0, 0, 42],
                encode_string("items"),
                vec![0x05, 0, 0, 0, 2],
                encode_string("a"),
                vec![0x07, 1],
            ]
            .concat();

            assert_eq!(
                decode(&payload),
                Ok(Value::Map(vec![
                    (Value::String("count".into()), Value::Integer(42)),
                    (
                        Value::String("items".into()),
                        Value::List(vec![Value::String("a".into()), Value::Bool(true)])
                    )
                ]))
            );
        }

        #[test]
        fn rejects_invalid_payloads() {
            assert_eq!(decode(&[0xff]), Err(DecodeError::UnknownTag(0xff)));
            assert_eq!(
                decode(&[0x03, 0, 0, 0, 4, b'a']),
                Err(DecodeError::UnexpectedEof)
            );

            let mut payload = encode_string("ok");
            payload.push(0);

            assert_eq!(decode(&payload), Err(DecodeError::TrailingBytes(1)));
        }

        fn encode_string(value: &str) -> Vec<u8> {
            let mut output = vec![0x03];
            output.extend_from_slice(&(value.len() as u32).to_be_bytes());
            output.extend_from_slice(value.as_bytes());
            output
        }
    }
}

/// Allocate memory in the WASM linear memory.
///
/// Called by the JS host to allocate space before writing data
/// (strings, binary blobs) into WASM memory.
///
/// Returns an aligned, non-null pointer even for size 0.
#[no_mangle]
pub extern "C" fn alloc(size: usize) -> *mut u8 {
    if size == 0 {
        // Return a well-aligned dangling pointer instead of
        // invoking the allocator with a zero-size layout.
        return core::mem::align_of::<u8>() as *mut u8;
    }
    let mut buf = Vec::with_capacity(size);
    let ptr = buf.as_mut_ptr();
    core::mem::forget(buf);
    ptr
}

/// Deallocate memory previously allocated with `alloc`.
///
/// Skips deallocation for size 0 (which returns a dangling pointer from `alloc`).
#[no_mangle]
pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
    if size == 0 {
        return;
    }
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, size));
    }
}
