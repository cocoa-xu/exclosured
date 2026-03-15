use exclosured_guest as exclosured;

/// Process text input: demonstrates compute-mode WASM with progress reporting.
///
/// In a real application, this could run an ONNX model for text classification,
/// NER, sentiment analysis, etc. The pattern is the same:
///   1. Receive input from LiveView via JS hook
///   2. Process locally in WASM (no server round-trip for heavy compute)
///   3. Emit progress events back to LiveView
///   4. Return final result
#[no_mangle]
pub extern "C" fn process(input_ptr: *const u8, input_len: usize) -> i32 {
    let input = unsafe { core::slice::from_raw_parts(input_ptr, input_len) };
    let text = match core::str::from_utf8(input) {
        Ok(s) => s,
        Err(_) => return -1,
    };

    exclosured::emit("progress", r#"{"percent": 10}"#);

    // Simulate analysis: count words, chars, sentences
    let word_count = text.split_whitespace().count();
    let char_count = text.chars().count();
    let sentence_count = text.chars().filter(|&c| c == '.' || c == '!' || c == '?').count();

    exclosured::emit("progress", r#"{"percent": 40}"#);

    // Character frequency analysis
    let mut freq = [0u32; 26];
    for c in text.chars() {
        if c.is_ascii_alphabetic() {
            let idx = (c.to_ascii_lowercase() as u8 - b'a') as usize;
            freq[idx] += 1;
        }
    }

    exclosured::emit("progress", r#"{"percent": 70}"#);

    // Find top 3 most frequent characters
    let mut top: Vec<(char, u32)> = freq
        .iter()
        .enumerate()
        .filter(|(_, &count)| count > 0)
        .map(|(i, &count)| ((b'a' + i as u8) as char, count))
        .collect();
    top.sort_by(|a, b| b.1.cmp(&a.1));
    top.truncate(3);

    let top_chars: Vec<String> = top.iter().map(|(c, n)| format!("'{}': {}", c, n)).collect();

    exclosured::emit("progress", r#"{"percent": 90}"#);

    // Build result summary
    let result = format!(
        "Words: {}, Characters: {}, Sentences: {}, Top chars: [{}]",
        word_count,
        char_count,
        sentence_count.max(1),
        top_chars.join(", ")
    );

    // Emit the full result as a structured event
    let payload = format!(
        r#"{{"words":{}, "chars":{}, "sentences":{}, "summary":"{}"}}"#,
        word_count,
        char_count,
        sentence_count.max(1),
        result
    );
    exclosured::emit("result", &payload);

    exclosured::emit("progress", r#"{"percent": 100}"#);

    word_count as i32
}

/// Load and process a model file (demonstrates asset loading pattern).
///
/// In a real app, this would accept an ONNX model binary loaded via
/// `ExclosuredLoader.loadAsset()` and initialize a runtime.
#[no_mangle]
pub extern "C" fn load_model(data_ptr: *const u8, data_len: usize) -> i32 {
    let _data = unsafe { core::slice::from_raw_parts(data_ptr, data_len) };
    exclosured::emit("model_loaded", r#"{"status": "ok"}"#);
    0
}
