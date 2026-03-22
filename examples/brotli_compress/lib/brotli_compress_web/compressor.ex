defmodule BrotliCompressWeb.Compressor do
  @moduledoc """
  Inline WASM module that performs brotli compression using the Rust `brotli` crate.

  Browsers can decompress brotli (via Content-Encoding headers), but the
  CompressionStream API only supports gzip and deflate. This module brings
  brotli *compression* to the browser via WebAssembly.

  ## Buffer protocol

  The first 4 bytes of the buffer contain the input length as a little-endian
  u32. The actual data starts at byte 4. This avoids null-byte trimming issues
  with binary files that may contain or end with zero bytes.

  On return, the compressed output is written starting at byte 0, and the
  function returns the compressed length.
  """

  use Exclosured.Inline

  defwasm :compress, args: [data: :binary, quality: :i32], deps: [{"brotli", "7.0"}] do
    ~RUST"""
    // First 4 bytes: input length as little-endian u32
    if data.len() < 4 {
        return -1;
    }
    let input_len = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    if input_len == 0 || 4 + input_len > data.len() {
        return 0;
    }
    let input = data[4..4 + input_len].to_vec();

    let mut output = Vec::new();
    let mut params = brotli::enc::BrotliEncoderParams::default();
    params.quality = if quality >= 0 && quality <= 11 { quality } else { 4 };
    match brotli::enc::BrotliCompress(&mut input.as_slice(), &mut output, &params) {
        Ok(_) => {
            let n = output.len().min(data.len());
            data[..n].copy_from_slice(&output[..n]);
            return n as i32;
        }
        Err(_) => return -1,
    }
    """
  end
end
