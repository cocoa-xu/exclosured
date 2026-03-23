defmodule LiveSvelteWasm.OT do
  @moduledoc """
  Operational Transformation engine for collaborative text editing.

  Operations are lists of components:
  - positive integer N: retain N characters (codepoints)
  - binary string: insert that string
  - negative integer N: delete |N| characters (codepoints)

  All positions are measured in Unicode codepoints (not graphemes, not bytes)
  to match the JS client which uses `Array.from(str).length`.

  Example: [5, "hello", -3, 10]
  = retain 5, insert "hello", delete 3, retain 10
  """

  @type op_component :: integer() | String.t()
  @type operation :: [op_component()]

  # -- Codepoint helpers (used consistently for cross-language compatibility) ---

  # Count Unicode codepoints (matches JS `Array.from(str).length`)
  defp cp_len(str), do: str |> String.codepoints() |> length()

  # Split string at codepoint position N
  defp cp_split_at(str, n) do
    {left, right} = str |> String.codepoints() |> Enum.split(n)
    {Enum.join(left), Enum.join(right)}
  end

  # Slice from codepoint position start, take count codepoints
  defp cp_slice(str, start, count) do
    str |> String.codepoints() |> Enum.drop(start) |> Enum.take(count) |> Enum.join()
  end

  # -- Apply ------------------------------------------------------------------

  @doc "Apply an operation to a document string."
  @spec apply(String.t(), operation()) :: {:ok, String.t()} | {:error, term()}
  def apply(doc, ops) do
    apply_loop(doc, ops, [])
  catch
    {:ot_error, reason} -> {:error, reason}
  end

  defp apply_loop("", [], acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

  defp apply_loop(rest, [], _acc) when byte_size(rest) > 0,
    do: throw({:ot_error, :trailing_input})

  defp apply_loop(doc, [comp | rest], acc) when is_integer(comp) and comp > 0 do
    if cp_len(doc) < comp, do: throw({:ot_error, :retain_past_end})
    {kept, remaining} = cp_split_at(doc, comp)
    apply_loop(remaining, rest, [kept | acc])
  end

  defp apply_loop(doc, [comp | rest], acc) when is_binary(comp) do
    apply_loop(doc, rest, [comp | acc])
  end

  defp apply_loop(doc, [comp | rest], acc) when is_integer(comp) and comp < 0 do
    n = abs(comp)
    if cp_len(doc) < n, do: throw({:ot_error, :delete_past_end})
    {_deleted, remaining} = cp_split_at(doc, n)
    apply_loop(remaining, rest, acc)
  end

  defp apply_loop(doc, [0 | rest], acc), do: apply_loop(doc, rest, acc)

  # -- Transform --------------------------------------------------------------

  @doc """
  Transform two concurrent operations A and B (both based on the same document)
  into {A', B'} such that apply(apply(doc, A), B') == apply(apply(doc, B), A').

  `priority` is :left or :right — determines tie-breaking for concurrent inserts
  at the same position. :left means A's insert goes first.
  """
  @spec transform(operation(), operation(), :left | :right) ::
          {:ok, {operation(), operation()}} | {:error, term()}
  def transform(ops_a, ops_b, priority \\ :left) do
    {a_prime, b_prime} =
      transform_loop(normalize(ops_a), normalize(ops_b), priority, [], [])

    {:ok, {compact(a_prime), compact(b_prime)}}
  catch
    {:ot_error, reason} -> {:error, reason}
  end

  defp transform_loop([], [], _pri, a_acc, b_acc) do
    {Enum.reverse(a_acc), Enum.reverse(b_acc)}
  end

  # A inserts
  defp transform_loop([a | a_rest], b_ops, pri, a_acc, b_acc) when is_binary(a) do
    len = cp_len(a)
    transform_loop(a_rest, b_ops, pri, [a | a_acc], [len | b_acc])
  end

  # B inserts
  defp transform_loop(a_ops, [b | b_rest], pri, a_acc, b_acc) when is_binary(b) do
    len = cp_len(b)
    transform_loop(a_ops, b_rest, pri, [len | a_acc], [b | b_acc])
  end

  # Both retain
  defp transform_loop([a | a_rest], [b | b_rest], pri, a_acc, b_acc)
       when is_integer(a) and a > 0 and is_integer(b) and b > 0 do
    min_len = min(a, b)
    a_remaining = if a - min_len > 0, do: [a - min_len | a_rest], else: a_rest
    b_remaining = if b - min_len > 0, do: [b - min_len | b_rest], else: b_rest
    transform_loop(a_remaining, b_remaining, pri, [min_len | a_acc], [min_len | b_acc])
  end

  # A deletes, B retains
  defp transform_loop([a | a_rest], [b | b_rest], pri, a_acc, b_acc)
       when is_integer(a) and a < 0 and is_integer(b) and b > 0 do
    del_len = abs(a)
    min_len = min(del_len, b)

    a_remaining =
      if del_len - min_len > 0, do: [-(del_len - min_len) | a_rest], else: a_rest

    b_remaining = if b - min_len > 0, do: [b - min_len | b_rest], else: b_rest
    transform_loop(a_remaining, b_remaining, pri, [-min_len | a_acc], b_acc)
  end

  # A retains, B deletes
  defp transform_loop([a | a_rest], [b | b_rest], pri, a_acc, b_acc)
       when is_integer(a) and a > 0 and is_integer(b) and b < 0 do
    del_len = abs(b)
    min_len = min(a, del_len)
    a_remaining = if a - min_len > 0, do: [a - min_len | a_rest], else: a_rest

    b_remaining =
      if del_len - min_len > 0, do: [-(del_len - min_len) | b_rest], else: b_rest

    transform_loop(a_remaining, b_remaining, pri, a_acc, [-min_len | b_acc])
  end

  # Both delete the same region
  defp transform_loop([a | a_rest], [b | b_rest], pri, a_acc, b_acc)
       when is_integer(a) and a < 0 and is_integer(b) and b < 0 do
    del_a = abs(a)
    del_b = abs(b)
    min_len = min(del_a, del_b)

    a_remaining =
      if del_a - min_len > 0, do: [-(del_a - min_len) | a_rest], else: a_rest

    b_remaining =
      if del_b - min_len > 0, do: [-(del_b - min_len) | b_rest], else: b_rest

    transform_loop(a_remaining, b_remaining, pri, a_acc, b_acc)
  end

  # One side exhausted but other has inserts remaining
  defp transform_loop([], [b | b_rest], pri, a_acc, b_acc) when is_binary(b) do
    len = cp_len(b)
    transform_loop([], b_rest, pri, [len | a_acc], [b | b_acc])
  end

  defp transform_loop([a | a_rest], [], pri, a_acc, b_acc) when is_binary(a) do
    len = cp_len(a)
    transform_loop(a_rest, [], pri, [a | a_acc], [len | b_acc])
  end

  # -- Compose -----------------------------------------------------------------

  @doc "Compose two sequential operations into one: compose(A, B) where A is applied first."
  @spec compose(operation(), operation()) :: {:ok, operation()} | {:error, term()}
  def compose(ops_a, ops_b) do
    result = compose_loop(normalize(ops_a), normalize(ops_b), [])
    {:ok, compact(result)}
  catch
    {:ot_error, reason} -> {:error, reason}
  end

  defp compose_loop([], [], acc), do: Enum.reverse(acc)

  # A's insert is consumed by B
  defp compose_loop([a | a_rest], b_ops, acc) when is_binary(a) do
    len = cp_len(a)
    consume_insert(a, len, a_rest, b_ops, acc)
  end

  defp compose_loop(a_ops, [b | b_rest], acc) when is_binary(b) do
    compose_loop(a_ops, b_rest, [b | acc])
  end

  # Both retain
  defp compose_loop([a | a_rest], [b | b_rest], acc)
       when is_integer(a) and a > 0 and is_integer(b) and b > 0 do
    min_len = min(a, b)
    a_remaining = if a - min_len > 0, do: [a - min_len | a_rest], else: a_rest
    b_remaining = if b - min_len > 0, do: [b - min_len | b_rest], else: b_rest
    compose_loop(a_remaining, b_remaining, [min_len | acc])
  end

  # A retains, B deletes
  defp compose_loop([a | a_rest], [b | b_rest], acc)
       when is_integer(a) and a > 0 and is_integer(b) and b < 0 do
    del_len = abs(b)
    min_len = min(a, del_len)
    a_remaining = if a - min_len > 0, do: [a - min_len | a_rest], else: a_rest

    b_remaining =
      if del_len - min_len > 0, do: [-(del_len - min_len) | b_rest], else: b_rest

    compose_loop(a_remaining, b_remaining, [-min_len | acc])
  end

  # A deletes
  defp compose_loop([a | a_rest], b_ops, acc) when is_integer(a) and a < 0 do
    compose_loop(a_rest, b_ops, [a | acc])
  end

  # Remaining
  defp compose_loop([], [b | b_rest], acc) when is_integer(b) do
    compose_loop([], b_rest, [b | acc])
  end

  defp compose_loop([a | a_rest], [], acc) when is_integer(a) and a < 0 do
    compose_loop(a_rest, [], [a | acc])
  end

  # Helper: an insert from A is consumed by B's retain/delete
  defp consume_insert(ins, ins_len, a_rest, [b | b_rest], acc)
       when is_integer(b) and b > 0 do
    if ins_len <= b do
      b_remaining = if b - ins_len > 0, do: [b - ins_len | b_rest], else: b_rest
      compose_loop(a_rest, b_remaining, [ins | acc])
    else
      {kept, rest_str} = cp_split_at(ins, b)
      rest_len = cp_len(rest_str)
      consume_insert(rest_str, rest_len, a_rest, b_rest, [kept | acc])
    end
  end

  defp consume_insert(ins, ins_len, a_rest, [b | b_rest], acc)
       when is_integer(b) and b < 0 do
    del_len = abs(b)

    if ins_len <= del_len do
      b_remaining =
        if del_len - ins_len > 0, do: [-(del_len - ins_len) | b_rest], else: b_rest

      compose_loop(a_rest, b_remaining, acc)
    else
      {_deleted, rest_str} = cp_split_at(ins, del_len)
      rest_len = cp_len(rest_str)
      consume_insert(rest_str, rest_len, a_rest, b_rest, acc)
    end
  end

  defp consume_insert(ins, ins_len, a_rest, [b | b_rest], acc) when is_binary(b) do
    consume_insert(ins, ins_len, a_rest, b_rest, [b | acc])
  end

  defp consume_insert(ins, _ins_len, a_rest, [], acc) do
    compose_loop(a_rest, [], [ins | acc])
  end

  # -- Helpers -----------------------------------------------------------------

  @doc "Calculate the base (input) length of an operation (in codepoints)."
  def base_length(ops) do
    Enum.reduce(ops, 0, fn
      n, acc when is_integer(n) and n > 0 -> acc + n
      n, acc when is_integer(n) and n < 0 -> acc + abs(n)
      s, acc when is_binary(s) -> acc
      _, acc -> acc
    end)
  end

  @doc "Calculate the target (output) length of an operation (in codepoints)."
  def target_length(ops) do
    Enum.reduce(ops, 0, fn
      n, acc when is_integer(n) and n > 0 -> acc + n
      n, acc when is_integer(n) and n < 0 -> acc
      s, acc when is_binary(s) -> acc + cp_len(s)
      _, acc -> acc
    end)
  end

  @doc "Build an operation from a text diff (old_text -> new_text)."
  def from_diff(old_text, new_text) do
    {prefix_len, old_mid, new_mid} = common_prefix(old_text, new_text)
    {suffix_len, old_core, new_core} = common_suffix(old_mid, new_mid)

    ops = []
    ops = if prefix_len > 0, do: [prefix_len | ops], else: ops

    old_core_len = cp_len(old_core)
    ops = if old_core_len > 0, do: [-old_core_len | ops], else: ops
    ops = if byte_size(new_core) > 0, do: [new_core | ops], else: ops

    ops = if suffix_len > 0, do: [suffix_len | ops], else: ops

    compact(Enum.reverse(ops))
  end

  defp common_prefix(a, b) do
    a_cps = String.codepoints(a)
    b_cps = String.codepoints(b)
    len = common_prefix_len(a_cps, b_cps, 0)
    {_, a_rest} = cp_split_at(a, len)
    {_, b_rest} = cp_split_at(b, len)
    {len, a_rest, b_rest}
  end

  defp common_prefix_len([c | a_rest], [c | b_rest], n),
    do: common_prefix_len(a_rest, b_rest, n + 1)

  defp common_prefix_len(_, _, n), do: n

  defp common_suffix(a, b) do
    a_cps = String.codepoints(a) |> Enum.reverse()
    b_cps = String.codepoints(b) |> Enum.reverse()
    len = common_prefix_len(a_cps, b_cps, 0)

    a_end = cp_len(a) - len
    b_end = cp_len(b) - len

    {len, cp_slice(a, 0, max(a_end, 0)), cp_slice(b, 0, max(b_end, 0))}
  end

  # Remove zero-ops and merge adjacent same-type components
  defp compact(ops), do: ops |> normalize() |> merge_adjacent([]) |> Enum.reverse()

  defp normalize(ops), do: Enum.reject(ops, &(&1 == 0 || &1 == ""))

  defp merge_adjacent([], acc), do: acc

  defp merge_adjacent([a | rest], [b | acc_rest])
       when is_integer(a) and a > 0 and is_integer(b) and b > 0 do
    merge_adjacent(rest, [a + b | acc_rest])
  end

  defp merge_adjacent([a | rest], [b | acc_rest])
       when is_integer(a) and a < 0 and is_integer(b) and b < 0 do
    merge_adjacent(rest, [a + b | acc_rest])
  end

  defp merge_adjacent([a | rest], [b | acc_rest])
       when is_binary(a) and is_binary(b) do
    merge_adjacent(rest, [b <> a | acc_rest])
  end

  defp merge_adjacent([comp | rest], acc) do
    merge_adjacent(rest, [comp | acc])
  end
end
