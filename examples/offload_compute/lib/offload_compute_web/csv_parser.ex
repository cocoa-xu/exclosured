defmodule OffloadComputeWeb.CsvParser do
  use Exclosured.Inline

  defwasm :parse_csv, args: [data: :binary] do
    """
    // Interpret the mutable data buffer as a UTF-8 string
    let input = match core::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => {
            let err = b"{\\"error\\":\\"Invalid UTF-8\\"}";
            let n = err.len();
            data[..n].copy_from_slice(err);
            return n as i32;
        }
    };

    let mut rows: i32 = 0;
    let mut cols: i32 = 0;
    let mut numeric_count: i32 = 0;
    let mut sum: f64 = 0.0;
    let mut min: f64 = f64::MAX;
    let mut max: f64 = f64::MIN;
    let mut is_header = true;

    // Parse CSV line by line
    let mut line_start = 0usize;
    let bytes = input.as_bytes();
    let total_len = bytes.len();
    let mut pos = 0usize;

    while pos <= total_len {
        // Find end of line or end of input
        let at_end = pos == total_len;
        let is_newline = !at_end && (bytes[pos] == b'\\n' || bytes[pos] == b'\\r');

        if is_newline || at_end {
            let line_end = pos;
            let line = &bytes[line_start..line_end];

            // Skip empty lines
            if !line.is_empty() {
                if is_header {
                    // Count columns from header
                    cols = 1;
                    let mut i = 0usize;
                    while i < line.len() {
                        if line[i] == b',' {
                            cols += 1;
                        }
                        i += 1;
                    }
                    is_header = false;
                } else {
                    rows += 1;
                    // Parse each field for numeric values
                    let mut field_start = 0usize;
                    let mut fi = 0usize;
                    while fi <= line.len() {
                        let field_end = fi == line.len() || line[fi] == b',';
                        if field_end {
                            let field = &line[field_start..fi];
                            // Trim whitespace
                            let mut fs = 0usize;
                            while fs < field.len() && (field[fs] == b' ' || field[fs] == b'\\t') {
                                fs += 1;
                            }
                            let mut fe = field.len();
                            while fe > fs && (field[fe - 1] == b' ' || field[fe - 1] == b'\\t') {
                                fe -= 1;
                            }
                            let trimmed = &field[fs..fe];

                            // Try parsing as f64 manually
                            if !trimmed.is_empty() {
                                let mut valid = true;
                                let mut has_digit = false;
                                let mut dot_count = 0i32;
                                let mut ci = 0usize;
                                // Allow leading minus
                                if trimmed[0] == b'-' {
                                    ci = 1;
                                }
                                while ci < trimmed.len() {
                                    if trimmed[ci] >= b'0' && trimmed[ci] <= b'9' {
                                        has_digit = true;
                                    } else if trimmed[ci] == b'.' {
                                        dot_count += 1;
                                        if dot_count > 1 {
                                            valid = false;
                                        }
                                    } else {
                                        valid = false;
                                    }
                                    ci += 1;
                                }
                                if valid && has_digit {
                                    // Manual f64 parse
                                    let mut val: f64 = 0.0;
                                    let mut frac: f64 = 0.0;
                                    let mut frac_div: f64 = 1.0;
                                    let mut in_frac = false;
                                    let mut neg = false;
                                    let mut pi = 0usize;
                                    if trimmed[0] == b'-' {
                                        neg = true;
                                        pi = 1;
                                    }
                                    while pi < trimmed.len() {
                                        if trimmed[pi] == b'.' {
                                            in_frac = true;
                                        } else {
                                            let d = (trimmed[pi] - b'0') as f64;
                                            if in_frac {
                                                frac_div *= 10.0;
                                                frac += d / frac_div;
                                            } else {
                                                val = val * 10.0 + d;
                                            }
                                        }
                                        pi += 1;
                                    }
                                    val += frac;
                                    if neg { val = -val; }

                                    numeric_count += 1;
                                    sum += val;
                                    if val < min { min = val; }
                                    if val > max { max = val; }
                                }
                            }

                            field_start = fi + 1;
                        }
                        fi += 1;
                    }
                }
            }

            // Skip \\r\\n pairs
            if is_newline && pos + 1 < total_len && bytes[pos] == b'\\r' && bytes[pos + 1] == b'\\n' {
                pos += 1;
            }
            line_start = pos + 1;
        }
        pos += 1;
    }

    let avg: f64 = if numeric_count > 0 { sum / numeric_count as f64 } else { 0.0 };

    // If no numeric values were found, reset min/max to 0
    if numeric_count == 0 {
        min = 0.0;
        max = 0.0;
    }

    // Format result as JSON using manual string building
    // We avoid alloc::format! since we cannot rely on std being available
    // Instead, build the JSON byte by byte into the data buffer

    // Helper: write an i32 into buffer, return bytes written
    fn write_i32(buf: &mut [u8], offset: usize, mut val: i32) -> usize {
        if val == 0 {
            buf[offset] = b'0';
            return 1;
        }
        let neg = val < 0;
        if neg { val = -val; }
        let mut tmp = [0u8; 12];
        let mut ti = 0usize;
        while val > 0 {
            tmp[ti] = b'0' + (val % 10) as u8;
            val /= 10;
            ti += 1;
        }
        let mut written = 0usize;
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

    // Helper: write an f64 with 2 decimal places into buffer, return bytes written
    fn write_f64(buf: &mut [u8], offset: usize, val: f64) -> usize {
        let neg = val < 0.0;
        let abs_val = if neg { -val } else { val };
        let int_part = abs_val as u64;
        let frac_part = ((abs_val - int_part as f64) * 100.0 + 0.5) as u64;

        let mut written = 0usize;
        if neg {
            buf[offset] = b'-';
            written += 1;
        }

        // Write integer part
        if int_part == 0 {
            buf[offset + written] = b'0';
            written += 1;
        } else {
            let mut tmp = [0u8; 20];
            let mut ti = 0usize;
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

        // Decimal point and fractional part
        buf[offset + written] = b'.';
        written += 1;
        buf[offset + written] = b'0' + (frac_part / 10 % 10) as u8;
        written += 1;
        buf[offset + written] = b'0' + (frac_part % 10) as u8;
        written += 1;

        written
    }

    // Build JSON: {"rows":N,"columns":N,"numeric_values":N,"min":X,"max":X,"avg":X}
    let mut off = 0usize;
    let prefix = b"{\\"rows\\":";
    data[off..off + prefix.len()].copy_from_slice(prefix);
    off += prefix.len();

    off += write_i32(data, off, rows);

    let s = b",\\"columns\\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();

    off += write_i32(data, off, cols);

    let s = b",\\"numeric_values\\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();

    off += write_i32(data, off, numeric_count);

    let s = b",\\"min\\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();

    off += write_f64(data, off, min);

    let s = b",\\"max\\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();

    off += write_f64(data, off, max);

    let s = b",\\"avg\\":";
    data[off..off + s.len()].copy_from_slice(s);
    off += s.len();

    off += write_f64(data, off, avg);

    data[off] = b'}';
    off += 1;

    off as i32
    """
  end
end
