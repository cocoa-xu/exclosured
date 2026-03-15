defmodule Exclosured.Protocol do
  @moduledoc """
  Binary encoding protocol for high-frequency state synchronization.

  Encodes Elixir terms into compact binary format for efficient
  transfer to WASM modules, avoiding JSON serialization overhead.

  ## Wire Format

  Each value is prefixed with a 1-byte type tag:

    - `0x01` - integer (signed 64-bit big-endian)
    - `0x02` - float (64-bit IEEE 754)
    - `0x03` - string (32-bit length prefix + UTF-8 bytes)
    - `0x04` - binary (32-bit length prefix + raw bytes)
    - `0x05` - list (32-bit count + encoded elements)
    - `0x06` - map (32-bit count + key/value pairs)
    - `0x07` - boolean (1 byte: 0 = false, 1 = true)
    - `0x08` - nil
    - `0x09` - atom (encoded as string)
  """

  @tag_int 0x01
  @tag_float 0x02
  @tag_string 0x03
  @tag_binary 0x04
  @tag_list 0x05
  @tag_map 0x06
  @tag_bool 0x07
  @tag_nil 0x08
  @tag_atom 0x09

  @doc """
  Encode an Elixir term into the binary wire format.
  """
  def encode(term) do
    encode_term(term)
  end

  @doc """
  Decode a binary wire format back into an Elixir term.
  """
  def decode(binary) when is_binary(binary) do
    {term, ""} = decode_term(binary)
    term
  end

  # Encoding

  defp encode_term(nil), do: <<@tag_nil>>
  defp encode_term(true), do: <<@tag_bool, 1>>
  defp encode_term(false), do: <<@tag_bool, 0>>

  defp encode_term(n) when is_integer(n) do
    <<@tag_int, n::signed-big-64>>
  end

  defp encode_term(f) when is_float(f) do
    <<@tag_float, f::float-64>>
  end

  defp encode_term(a) when is_atom(a) do
    str = Atom.to_string(a)
    <<@tag_atom, byte_size(str)::unsigned-big-32, str::binary>>
  end

  defp encode_term(s) when is_binary(s) do
    if String.valid?(s) do
      <<@tag_string, byte_size(s)::unsigned-big-32, s::binary>>
    else
      <<@tag_binary, byte_size(s)::unsigned-big-32, s::binary>>
    end
  end

  defp encode_term(list) when is_list(list) do
    count = length(list)
    encoded = Enum.map(list, &encode_term/1) |> IO.iodata_to_binary()
    <<@tag_list, count::unsigned-big-32, encoded::binary>>
  end

  defp encode_term(map) when is_map(map) do
    count = map_size(map)

    encoded =
      map
      |> Enum.map(fn {k, v} ->
        [encode_term(k), encode_term(v)]
      end)
      |> IO.iodata_to_binary()

    <<@tag_map, count::unsigned-big-32, encoded::binary>>
  end

  # Decoding

  defp decode_term(<<@tag_nil, rest::binary>>), do: {nil, rest}
  defp decode_term(<<@tag_bool, 1, rest::binary>>), do: {true, rest}
  defp decode_term(<<@tag_bool, 0, rest::binary>>), do: {false, rest}

  defp decode_term(<<@tag_int, n::signed-big-64, rest::binary>>), do: {n, rest}
  defp decode_term(<<@tag_float, f::float-64, rest::binary>>), do: {f, rest}

  defp decode_term(<<@tag_string, len::unsigned-big-32, str::binary-size(len), rest::binary>>) do
    {str, rest}
  end

  defp decode_term(<<@tag_binary, len::unsigned-big-32, data::binary-size(len), rest::binary>>) do
    {data, rest}
  end

  defp decode_term(<<@tag_atom, len::unsigned-big-32, str::binary-size(len), rest::binary>>) do
    {String.to_existing_atom(str), rest}
  end

  defp decode_term(<<@tag_list, count::unsigned-big-32, rest::binary>>) do
    {items, rest} = decode_n(rest, count, [])
    {items, rest}
  end

  defp decode_term(<<@tag_map, count::unsigned-big-32, rest::binary>>) do
    {pairs, rest} = decode_pairs(rest, count, [])
    {Map.new(pairs), rest}
  end

  defp decode_n(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_n(binary, n, acc) do
    {term, rest} = decode_term(binary)
    decode_n(rest, n - 1, [term | acc])
  end

  defp decode_pairs(rest, 0, acc), do: {acc, rest}

  defp decode_pairs(binary, n, acc) do
    {key, rest} = decode_term(binary)
    {value, rest} = decode_term(rest)
    decode_pairs(rest, n - 1, [{key, value} | acc])
  end
end
