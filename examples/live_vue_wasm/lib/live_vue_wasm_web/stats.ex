defmodule LiveVueWasmWeb.Stats do
  @moduledoc """
  Inline WASM module that computes rolling statistics on a JSON array of f64 values.

  Given a JSON array like `[1.0, 2.5, 3.7, ...]`, it computes:
  count, mean, min, max, standard deviation, p50, p90, and p99.
  The result is written back as a JSON object into the same buffer.
  """
  use Exclosured.Inline

  defwasm :compute_stats, args: [data: :binary] do
    ~RUST"""
    // Parse the data buffer as UTF-8
    let input = match core::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => {
            let err = b"{\"error\":\"Invalid UTF-8\"}";
            let n = err.len();
            data[..n].copy_from_slice(err);
            return n as i32;
        }
    };

    // Parse JSON array of numbers manually.
    // Expected format: [1.0, 2.5, -3.7, ...]
    let bytes = input.as_bytes();
    let len = bytes.len();

    // Collect values into a local array (max 4096 data points)
    let mut values = [0.0f64; 4096];
    let mut count: usize = 0;

    // Skip leading whitespace and '['
    let mut pos: usize = 0;
    while pos < len && (bytes[pos] == b' ' || bytes[pos] == b'\t' || bytes[pos] == b'\n' || bytes[pos] == b'\r') {
        pos += 1;
    }
    if pos < len && bytes[pos] == b'[' {
        pos += 1;
    }

    // Parse each number
    while pos < len && count < 4096 {
        // Skip whitespace and commas
        while pos < len && (bytes[pos] == b' ' || bytes[pos] == b',' || bytes[pos] == b'\t' || bytes[pos] == b'\n' || bytes[pos] == b'\r') {
            pos += 1;
        }
        if pos >= len || bytes[pos] == b']' {
            break;
        }

        // Parse a single f64 value
        let neg = if bytes[pos] == b'-' { pos += 1; true } else { false };
        let mut int_part: f64 = 0.0;
        let mut has_digit = false;

        while pos < len && bytes[pos] >= b'0' && bytes[pos] <= b'9' {
            int_part = int_part * 10.0 + (bytes[pos] - b'0') as f64;
            has_digit = true;
            pos += 1;
        }

        let mut frac: f64 = 0.0;
        if pos < len && bytes[pos] == b'.' {
            pos += 1;
            let mut divisor: f64 = 1.0;
            while pos < len && bytes[pos] >= b'0' && bytes[pos] <= b'9' {
                divisor *= 10.0;
                frac += (bytes[pos] - b'0') as f64 / divisor;
                has_digit = true;
                pos += 1;
            }
        }

        if has_digit {
            let mut val = int_part + frac;
            if neg { val = -val; }
            values[count] = val;
            count += 1;
        }
    }

    if count == 0 {
        let empty = b"{\"count\":0,\"mean\":0,\"min\":0,\"max\":0,\"std_dev\":0,\"p50\":0,\"p90\":0,\"p99\":0}";
        let n = empty.len();
        data[..n].copy_from_slice(empty);
        return n as i32;
    }

    // Compute basic statistics
    let mut sum: f64 = 0.0;
    let mut min_val: f64 = values[0];
    let mut max_val: f64 = values[0];
    let mut i: usize = 0;
    while i < count {
        sum += values[i];
        if values[i] < min_val { min_val = values[i]; }
        if values[i] > max_val { max_val = values[i]; }
        i += 1;
    }
    let mean = sum / count as f64;

    // Compute standard deviation
    let mut variance_sum: f64 = 0.0;
    i = 0;
    while i < count {
        let diff = values[i] - mean;
        variance_sum += diff * diff;
        i += 1;
    }
    let std_dev = {
        // Manual sqrt using Newton's method (no libm in wasm32 no_std-like env)
        let variance = variance_sum / count as f64;
        let mut guess = variance;
        if guess > 0.0 {
            let mut j = 0;
            while j < 50 {
                guess = (guess + variance / guess) * 0.5;
                j += 1;
            }
        }
        guess
    };

    // Sort for percentiles using insertion sort (good enough for <= 4096 elements)
    i = 1;
    while i < count {
        let key = values[i];
        let mut j = i;
        while j > 0 && values[j - 1] > key {
            values[j] = values[j - 1];
            j -= 1;
        }
        values[j] = key;
        i += 1;
    }

    // Compute percentiles using nearest-rank method
    let p50_idx = if count == 1 { 0 } else { (count * 50 / 100).min(count - 1) };
    let p90_idx = if count == 1 { 0 } else { (count * 90 / 100).min(count - 1) };
    let p99_idx = if count == 1 { 0 } else { (count * 99 / 100).min(count - 1) };

    let p50 = values[p50_idx];
    let p90 = values[p90_idx];
    let p99 = values[p99_idx];

    // Write result as JSON into the data buffer
    // Helpers for writing numeric values

    fn write_i32(buf: &mut [u8], offset: usize, mut val: i32) -> usize {
        if val == 0 {
            buf[offset] = b'0';
            return 1;
        }
        let neg = val < 0;
        if neg { val = -val; }
        let mut tmp = [0u8; 12];
        let mut ti: usize = 0;
        while val > 0 {
            tmp[ti] = b'0' + (val % 10) as u8;
            val /= 10;
            ti += 1;
        }
        let mut written: usize = 0;
        if neg {
            buf[offset] = b'-';
            written += 1;
        }
        let mut ri = ti;
        while ri > 0 {
            ri -= 1;
            buf[offset + written] = tmp[ri];
            written += 1;
        }
        written
    }

    fn write_f64(buf: &mut [u8], offset: usize, val: f64) -> usize {
        let neg = val < 0.0;
        let abs_val = if neg { -val } else { val };
        let int_part = abs_val as u64;
        let frac_part = ((abs_val - int_part as f64) * 100.0 + 0.5) as u64;

        let mut written: usize = 0;
        if neg {
            buf[offset] = b'-';
            written += 1;
        }

        if int_part == 0 {
            buf[offset + written] = b'0';
            written += 1;
        } else {
            let mut tmp = [0u8; 20];
            let mut ti: usize = 0;
            let mut v = int_part;
            while v > 0 {
                tmp[ti] = b'0' + (v % 10) as u8;
                v /= 10;
                ti += 1;
            }
            let mut ri = ti;
            while ri > 0 {
                ri -= 1;
                buf[offset + written] = tmp[ri];
                written += 1;
            }
        }

        buf[offset + written] = b'.';
        written += 1;
        buf[offset + written] = b'0' + (frac_part / 10 % 10) as u8;
        written += 1;
        buf[offset + written] = b'0' + (frac_part % 10) as u8;
        written += 1;

        written
    }

    // Build JSON result
    let mut off: usize = 0;

    let s = b"{\"count\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_i32(data, off, count as i32);

    let s = b",\"mean\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, mean);

    let s = b",\"min\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, min_val);

    let s = b",\"max\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, max_val);

    let s = b",\"std_dev\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, std_dev);

    let s = b",\"p50\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, p50);

    let s = b",\"p90\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, p90);

    let s = b",\"p99\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();
    off += write_f64(data, off, p99);

    data[off] = b'}';
    off += 1;

    off as i32
    """
  end
end
