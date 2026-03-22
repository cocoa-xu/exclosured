defmodule ConfidentialComputeWeb.Validators do
  use Exclosured.Inline

  @doc "Password strength scoring. Runs entirely in the browser."
  defwasm :check_password, args: [input: :binary] do
    ~RUST"""
    let s = match core::str::from_utf8(input) {
        Ok(v) => v,
        Err(_) => return -1,
    };

    let length = s.len();
    let mut score: i32 = 0;

    if length >= 8 { score += 1; }
    if length >= 12 { score += 1; }
    if length >= 16 { score += 1; }

    let mut has_lower = false;
    let mut has_upper = false;
    let mut has_digit = false;
    let mut has_special = false;

    for b in s.bytes() {
        if b >= b'a' && b <= b'z' { has_lower = true; }
        if b >= b'A' && b <= b'Z' { has_upper = true; }
        if b >= b'0' && b <= b'9' { has_digit = true; }
        if !((b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9')) {
            has_special = true;
        }
    }

    if has_lower { score += 1; }
    if has_upper { score += 1; }
    if has_digit { score += 1; }
    if has_special { score += 1; }

    // Penalty for common patterns (manual lowercase + substring check)
    let mut lower_buf = [0u8; 64];
    let take = if length < 64 { length } else { 64 };
    for i in 0..take {
        let b = s.as_bytes()[i];
        lower_buf[i] = if b >= b'A' && b <= b'Z' { b + 32 } else { b };
    }
    let lower = &lower_buf[..take];

    let patterns: &[&[u8]] = &[b"password", b"123456", b"qwerty", b"admin"];
    for pat in patterns {
        if take >= pat.len() {
            let end = take - pat.len() + 1;
            let mut j = 0usize;
            while j < end {
                if &lower[j..j + pat.len()] == *pat { score -= 2; break; }
                j += 1;
            }
        }
    }

    if score < 0 { score = 0; }
    if score > 7 { score = 7; }

    let label: &[u8] = match score {
        0..=2 => b"weak",
        3..=4 => b"fair",
        5..=6 => b"strong",
        _ => b"very_strong",
    };

    // Build JSON manually: {"score":N,"max":7,"label":"...","length":N}
    let mut out = [0u8; 256];
    let mut p = 0usize;

    macro_rules! w { ($slice:expr) => { out[p..p+$slice.len()].copy_from_slice($slice); p += $slice.len(); } }

    w!(b"{\"score\":");
    out[p] = b'0' + score as u8; p += 1;
    w!(b",\"max\":7,\"label\":\"");
    w!(label);
    w!(b"\",\"length\":");

    // Write length as decimal digits
    if length == 0 {
        out[p] = b'0'; p += 1;
    } else {
        let mut tmp = [0u8; 10];
        let mut t = 0usize;
        let mut rem = length;
        while rem > 0 { tmp[t] = b'0' + (rem % 10) as u8; t += 1; rem /= 10; }
        let mut k = 0usize;
        while k < t { out[p + k] = tmp[t - 1 - k]; k += 1; }
        p += t;
    }

    out[p] = b'}'; p += 1;

    input[..p].copy_from_slice(&out[..p]);
    return p as i32;
    """
  end

  @doc "SSN validation and masking. Only the masked value leaves the browser."
  defwasm :mask_ssn, args: [input: :binary] do
    ~RUST"""
    let s = match core::str::from_utf8(input) {
        Ok(v) => v,
        Err(_) => return -1,
    };

    // Extract digits only
    let mut digits = [0u8; 32];
    let mut dcount = 0usize;
    for b in s.bytes() {
        if b >= b'0' && b <= b'9' && dcount < 32 {
            digits[dcount] = b;
            dcount += 1;
        }
    }

    let mut out = [0u8; 256];
    let mut p = 0usize;

    macro_rules! w { ($slice:expr) => { out[p..p+$slice.len()].copy_from_slice($slice); p += $slice.len(); } }

    if dcount == 9 {
        w!(b"{\"valid\":true,\"masked\":\"***-**-");
        out[p] = digits[5]; p += 1;
        out[p] = digits[6]; p += 1;
        out[p] = digits[7]; p += 1;
        out[p] = digits[8]; p += 1;
        w!(b"\"}");
    } else {
        w!(b"{\"valid\":false,\"masked\":\"INVALID FORMAT\"}");
    }

    input[..p].copy_from_slice(&out[..p]);
    return p as i32;
    """
  end
end
