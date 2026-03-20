use wasm_bindgen::prelude::*;

// Re-export alloc/dealloc for memory management from the host
pub use exclosured_guest::{alloc, dealloc};

/// Find all primes up to `max_n`, emitting batches of results as "chunk" events.
///
/// Each chunk contains a JSON payload with the primes found in that batch,
/// the current progress percentage, and the batch number. When all batches
/// are processed, a "done" event is emitted with the total count.
#[wasm_bindgen]
pub fn find_primes(max_n: i32) -> i32 {
    let max = max_n as usize;
    let batch_size = 1000;
    let total_batches = if max == 0 { 1 } else { (max + batch_size - 1) / batch_size };
    let mut all_count: usize = 0;

    for batch_idx in 0..total_batches {
        let range_start = batch_idx * batch_size;
        let range_end = ((batch_idx + 1) * batch_size).min(max + 1);

        // Skip numbers below 2
        let check_start = if range_start < 2 { 2 } else { range_start };

        let mut batch_primes: Vec<usize> = Vec::new();
        for n in check_start..range_end {
            if is_prime(n) {
                batch_primes.push(n);
            }
        }

        all_count += batch_primes.len();
        let progress = ((batch_idx + 1) * 100 / total_batches) as u32;

        // Build JSON payload for this batch
        let primes_str = batch_primes
            .iter()
            .map(|p| p.to_string())
            .collect::<Vec<_>>()
            .join(",");

        let payload = format!(
            r#"{{"primes":[{}],"progress":{},"batch":{}}}"#,
            primes_str,
            progress,
            batch_idx + 1
        );

        exclosured_guest::emit("chunk", &payload);
    }

    exclosured_guest::emit("done", &format!(r#"{{"total":{}}}"#, all_count));
    all_count as i32
}

/// Trial division primality test.
fn is_prime(n: usize) -> bool {
    if n < 2 {
        return false;
    }
    if n < 4 {
        return true;
    }
    if n % 2 == 0 || n % 3 == 0 {
        return false;
    }
    let mut i = 5;
    while i * i <= n {
        if n % i == 0 || n % (i + 2) == 0 {
            return false;
        }
        i += 6;
    }
    true
}
