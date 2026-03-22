defmodule MatrixMulWeb.Multiplier do
  @moduledoc """
  Inline WASM module that performs matrix multiplication using the Rust `nalgebra` crate.

  Provides both f64 and f32 variants for fair benchmarking across engines.

  ## Buffer protocol

  The buffer contains two concatenated flat arrays in row-major order.
  - f64 variant: [A (N*N f64s LE), B (N*N f64s LE)], returns 8-byte f64 checksum
  - f32 variant: [A (N*N f32s LE), B (N*N f32s LE)], returns 4-byte f32 checksum
  """

  use Exclosured.Inline

  defwasm :matmul, args: [data: :binary, n: :i32], deps: [{"nalgebra", "0.33"}] do
    ~RUST"""
    use nalgebra::DMatrix;

    let n = n as usize;
    if n == 0 || data.len() < n * n * 16 { return -1; }

    let mut a_data = vec![0.0f64; n * n];
    let mut b_data = vec![0.0f64; n * n];

    for i in 0..n*n {
        let offset = i * 8;
        let bytes: [u8; 8] = data[offset..offset+8].try_into().unwrap();
        a_data[i] = f64::from_le_bytes(bytes);
    }
    for i in 0..n*n {
        let offset = (n*n + i) * 8;
        let bytes: [u8; 8] = data[offset..offset+8].try_into().unwrap();
        b_data[i] = f64::from_le_bytes(bytes);
    }

    let a = DMatrix::from_row_slice(n, n, &a_data);
    let b = DMatrix::from_row_slice(n, n, &b_data);
    let c = a * b;

    let sum: f64 = c.iter().sum();
    data[..8].copy_from_slice(&sum.to_le_bytes());
    return 8;
    """
  end

  defwasm :matmul_f32, args: [data: :binary, n: :i32], deps: [{"nalgebra", "0.33"}] do
    ~RUST"""
    use nalgebra::DMatrix;

    let n = n as usize;
    if n == 0 || data.len() < n * n * 8 { return -1; }

    let mut a_data = vec![0.0f32; n * n];
    let mut b_data = vec![0.0f32; n * n];

    for i in 0..n*n {
        let offset = i * 4;
        let bytes: [u8; 4] = data[offset..offset+4].try_into().unwrap();
        a_data[i] = f32::from_le_bytes(bytes);
    }
    for i in 0..n*n {
        let offset = (n*n + i) * 4;
        let bytes: [u8; 4] = data[offset..offset+4].try_into().unwrap();
        b_data[i] = f32::from_le_bytes(bytes);
    }

    let a = DMatrix::from_row_slice(n, n, &a_data);
    let b = DMatrix::from_row_slice(n, n, &b_data);
    let c = a * b;

    let sum: f32 = c.iter().sum();
    data[..4].copy_from_slice(&sum.to_le_bytes());
    return 4;
    """
  end

  defwasm :matmul_i32, args: [data: :binary, n: :i32], deps: [{"nalgebra", "0.33"}] do
    ~RUST"""
    use nalgebra::DMatrix;
    let n = n as usize;
    if n == 0 || data.len() < n * n * 8 { return -1; }
    let mut a_data = vec![0i32; n * n];
    let mut b_data = vec![0i32; n * n];
    for i in 0..n*n {
        let o = i * 4;
        a_data[i] = i32::from_le_bytes(data[o..o+4].try_into().unwrap());
    }
    for i in 0..n*n {
        let o = (n*n + i) * 4;
        b_data[i] = i32::from_le_bytes(data[o..o+4].try_into().unwrap());
    }
    let a = DMatrix::from_row_slice(n, n, &a_data);
    let b = DMatrix::from_row_slice(n, n, &b_data);
    let c = a * b;
    let sum: i64 = c.iter().map(|&x| x as i64).sum();
    data[..8].copy_from_slice(&sum.to_le_bytes());
    return 8;
    """
  end

  defwasm :matmul_i16, args: [data: :binary, n: :i32], deps: [{"nalgebra", "0.33"}] do
    ~RUST"""
    use nalgebra::DMatrix;
    let n = n as usize;
    if n == 0 || data.len() < n * n * 4 { return -1; }
    let mut a_data = vec![0i32; n * n];
    let mut b_data = vec![0i32; n * n];
    for i in 0..n*n {
        let o = i * 2;
        a_data[i] = i16::from_le_bytes(data[o..o+2].try_into().unwrap()) as i32;
    }
    for i in 0..n*n {
        let o = (n*n + i) * 2;
        b_data[i] = i16::from_le_bytes(data[o..o+2].try_into().unwrap()) as i32;
    }
    let a = DMatrix::from_row_slice(n, n, &a_data);
    let b = DMatrix::from_row_slice(n, n, &b_data);
    let c = a * b;
    let sum: i64 = c.iter().map(|&x| x as i64).sum();
    data[..8].copy_from_slice(&sum.to_le_bytes());
    return 8;
    """
  end

  defwasm :matmul_i8, args: [data: :binary, n: :i32], deps: [{"nalgebra", "0.33"}] do
    ~RUST"""
    use nalgebra::DMatrix;
    let n = n as usize;
    if n == 0 || data.len() < n * n * 2 { return -1; }
    let mut a_data = vec![0i32; n * n];
    let mut b_data = vec![0i32; n * n];
    for i in 0..n*n { a_data[i] = data[i] as i8 as i32; }
    for i in 0..n*n { b_data[i] = data[n*n + i] as i8 as i32; }
    let a = DMatrix::from_row_slice(n, n, &a_data);
    let b = DMatrix::from_row_slice(n, n, &b_data);
    let c = a * b;
    let sum: i64 = c.iter().map(|&x| x as i64).sum();
    data[..8].copy_from_slice(&sum.to_le_bytes());
    return 8;
    """
  end
end
