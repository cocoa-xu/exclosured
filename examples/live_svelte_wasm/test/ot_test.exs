defmodule LiveSvelteWasm.OTTest do
  use ExUnit.Case, async: true

  alias LiveSvelteWasm.OT

  # ---------------------------------------------------------------------------
  # apply/2
  # ---------------------------------------------------------------------------
  describe "apply/2" do
    test "empty op on empty doc" do
      assert {:ok, ""} = OT.apply("", [])
    end

    test "retain entire doc" do
      assert {:ok, "hello"} = OT.apply("hello", [5])
    end

    test "insert into empty doc" do
      assert {:ok, "hello"} = OT.apply("", ["hello"])
    end

    test "insert at beginning" do
      assert {:ok, "hello world"} = OT.apply("world", ["hello ", 5])
    end

    test "insert at end" do
      assert {:ok, "hello!"} = OT.apply("hello", [5, "!"])
    end

    test "insert in middle" do
      assert {:ok, "hello beautiful world"} = OT.apply("hello world", [6, "beautiful ", 5])
    end

    test "delete from beginning" do
      assert {:ok, "world"} = OT.apply("hello world", [-6, 5])
    end

    test "delete from end" do
      assert {:ok, "hello"} = OT.apply("hello world", [5, -6])
    end

    test "delete from middle" do
      assert {:ok, "held"} = OT.apply("hello world", [3, -7, 1])
    end

    test "mixed operations" do
      # "abcdef" -> retain 2, delete 2, insert "XY", retain 2
      assert {:ok, "abXYef"} = OT.apply("abcdef", [2, -2, "XY", 2])
    end

    test "error on retain past end" do
      assert {:error, :retain_past_end} = OT.apply("hi", [5])
    end

    test "error on delete past end" do
      assert {:error, :delete_past_end} = OT.apply("hi", [-5])
    end

    test "error on trailing input" do
      assert {:error, :trailing_input} = OT.apply("hello", [3])
    end
  end

  # ---------------------------------------------------------------------------
  # from_diff/2
  # ---------------------------------------------------------------------------
  describe "from_diff/2" do
    test "no change returns retain-only (identity op)" do
      op = OT.from_diff("hello", "hello")
      assert {:ok, "hello"} = OT.apply("hello", op)
      # No inserts or deletes
      assert Enum.all?(op, &is_integer/1)
    end

    test "insert at end" do
      op = OT.from_diff("hello", "hello world")
      assert {:ok, "hello world"} = OT.apply("hello", op)
    end

    test "insert at beginning" do
      op = OT.from_diff("world", "hello world")
      assert {:ok, "hello world"} = OT.apply("world", op)
    end

    test "delete from middle" do
      op = OT.from_diff("hello world", "held")
      assert {:ok, "held"} = OT.apply("hello world", op)
    end

    test "replace" do
      op = OT.from_diff("hello", "goodbye")
      assert {:ok, "goodbye"} = OT.apply("hello", op)
    end

    test "full delete" do
      op = OT.from_diff("hello", "")
      assert {:ok, ""} = OT.apply("hello", op)
    end

    test "insert into empty" do
      op = OT.from_diff("", "hello")
      assert {:ok, "hello"} = OT.apply("", op)
    end
  end

  # ---------------------------------------------------------------------------
  # transform/3 — convergence
  # ---------------------------------------------------------------------------
  describe "transform/3" do
    test "two inserts at different positions" do
      doc = "hello world"
      op_a = [5, " beautiful", 6]
      op_b = [11, "!"]

      assert_convergence(doc, op_a, op_b)
    end

    test "two inserts at same position (priority left)" do
      doc = "ab"
      op_a = [1, "X", 1]
      op_b = [1, "Y", 1]

      {:ok, {a_prime, b_prime}} = OT.transform(op_a, op_b, :left)
      {:ok, via_a} = OT.apply(doc, op_a)
      {:ok, result_ab} = OT.apply(via_a, b_prime)
      {:ok, via_b} = OT.apply(doc, op_b)
      {:ok, result_ba} = OT.apply(via_b, a_prime)

      assert result_ab == result_ba
    end

    test "insert vs delete (no overlap)" do
      doc = "abcdef"
      op_a = [2, "XX", 4]
      op_b = [4, -2]

      assert_convergence(doc, op_a, op_b)
    end

    test "delete vs insert at delete boundary" do
      doc = "abcdef"
      op_a = [2, -2, 2]
      op_b = [2, "X", 4]

      assert_convergence(doc, op_a, op_b)
    end

    test "two deletes at different positions" do
      doc = "abcdefgh"
      op_a = [2, -2, 4]
      op_b = [4, -2, 2]

      assert_convergence(doc, op_a, op_b)
    end

    test "overlapping deletes" do
      doc = "abcdefgh"
      op_a = [1, -4, 3]
      op_b = [3, -3, 2]

      assert_convergence(doc, op_a, op_b)
    end

    test "identical deletes" do
      doc = "abcdef"
      op_a = [2, -2, 2]
      op_b = [2, -2, 2]

      assert_convergence(doc, op_a, op_b)
    end

    test "one side is identity (retain all)" do
      doc = "hello"
      op_a = [2, "X", 3]
      op_b = [5]

      assert_convergence(doc, op_a, op_b)
    end

    test "both insert-only (empty doc)" do
      doc = ""
      op_a = ["hello"]
      op_b = ["world"]

      assert_convergence(doc, op_a, op_b)
    end
  end

  # ---------------------------------------------------------------------------
  # compose/2
  # ---------------------------------------------------------------------------
  describe "compose/2" do
    test "two sequential inserts" do
      op_a = ["hello"]
      op_b = [5, " world"]

      {:ok, composed} = OT.compose(op_a, op_b)
      assert {:ok, "hello world"} = OT.apply("", composed)
    end

    test "insert then delete (cancel out)" do
      op_a = [3, "XX", 3]
      op_b = [3, -2, 3]

      {:ok, composed} = OT.compose(op_a, op_b)
      assert {:ok, "abcdef"} = OT.apply("abcdef", composed)
    end

    test "two retains" do
      {:ok, composed} = OT.compose([5], [5])
      assert {:ok, "hello"} = OT.apply("hello", composed)
    end

    test "compose preserves semantics" do
      doc = "hello world"
      op_a = [5, " beautiful", 6]
      op_b = [21, "!"]

      {:ok, via_steps} = OT.apply(doc, op_a)
      {:ok, via_steps} = OT.apply(via_steps, op_b)

      {:ok, composed} = OT.compose(op_a, op_b)
      {:ok, via_composed} = OT.apply(doc, composed)

      assert via_steps == via_composed
    end
  end

  # ---------------------------------------------------------------------------
  # base_length / target_length
  # ---------------------------------------------------------------------------
  describe "length helpers" do
    test "base_length counts retains + deletes" do
      assert 11 == OT.base_length([5, " beautiful", -1, 5])
    end

    test "target_length counts retains + inserts" do
      assert 20 == OT.target_length([5, " beautiful", -1, 5])
    end
  end

  # ---------------------------------------------------------------------------
  # Property: convergence
  # ---------------------------------------------------------------------------
  describe "property: random convergence" do
    test "random insert-only operations converge" do
      for _ <- 1..50 do
        doc = random_string(10..30)
        op_a = random_insert_op(doc)
        op_b = random_insert_op(doc)
        assert_convergence(doc, op_a, op_b)
      end
    end

    test "random mixed operations converge" do
      for _ <- 1..50 do
        doc = random_string(10..30)
        op_a = random_op(doc)
        op_b = random_op(doc)
        assert_convergence(doc, op_a, op_b)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Unicode (codepoint-aware operations)
  # ---------------------------------------------------------------------------
  describe "unicode support" do
    test "apply with emoji" do
      # "hi😀bye" = h, i, 😀, b, y, e = 6 codepoints
      assert {:ok, "hi😀bye"} = OT.apply("hi😀bye", [6])
    end

    test "insert after emoji" do
      # retain 3 (h, i, 😀), insert "!", retain 3 (b, y, e)
      assert {:ok, "hi😀!bye"} = OT.apply("hi😀bye", [3, "!", 3])
    end

    test "delete emoji" do
      # retain 2 (h, i), delete 1 (😀), retain 3 (b, y, e)
      assert {:ok, "hibye"} = OT.apply("hi😀bye", [2, -1, 3])
    end

    test "from_diff with emoji insertion" do
      op = OT.from_diff("hello", "hel🎉lo")
      assert {:ok, "hel🎉lo"} = OT.apply("hello", op)
    end

    test "from_diff with emoji deletion" do
      op = OT.from_diff("hi😀bye", "hibye")
      assert {:ok, "hibye"} = OT.apply("hi😀bye", op)
    end

    test "transform with emoji in both ops" do
      doc = "a😀b"
      # Insert at pos 1 (after 'a')
      op_a = [1, "X", 2]
      # Insert at pos 2 (after '😀')
      op_b = [2, "Y", 1]
      assert_convergence(doc, op_a, op_b)
    end

    test "transform with multi-codepoint emoji" do
      # Flag emoji: 🇯🇵 is 2 codepoints (regional indicator symbols)
      doc = "a🇯🇵b"
      op_a = [1, "X", 3]
      op_b = [3, "Y", 1]
      assert_convergence(doc, op_a, op_b)
    end

    test "compose with emoji" do
      op_a = ["😀"]
      op_b = [1, "🎉"]
      {:ok, composed} = OT.compose(op_a, op_b)
      assert {:ok, "😀🎉"} = OT.apply("", composed)
    end

    test "from_diff with CJK characters" do
      op = OT.from_diff("hello世界", "hello新世界")
      assert {:ok, "hello新世界"} = OT.apply("hello世界", op)
    end

    test "base_length and target_length with emoji" do
      op = [2, "😀🎉", -1, 3]
      assert 6 == OT.base_length(op)
      assert 7 == OT.target_length(op)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  defp assert_convergence(doc, op_a, op_b) do
    {:ok, {a_prime, b_prime}} = OT.transform(op_a, op_b)

    {:ok, via_a} = OT.apply(doc, op_a)
    {:ok, via_a_then_b} = OT.apply(via_a, b_prime)

    {:ok, via_b} = OT.apply(doc, op_b)
    {:ok, via_b_then_a} = OT.apply(via_b, a_prime)

    assert via_a_then_b == via_b_then_a,
           """
           Convergence failed!
           Doc: #{inspect(doc)}
           Op A: #{inspect(op_a)}
           Op B: #{inspect(op_b)}
           A': #{inspect(a_prime)}
           B': #{inspect(b_prime)}
           Via A then B': #{inspect(via_a_then_b)}
           Via B then A': #{inspect(via_b_then_a)}
           """
  end

  defp random_string(len_range) do
    len = Enum.random(len_range)
    for(_ <- 1..len, do: Enum.random(?a..?z)) |> List.to_string()
  end

  defp random_insert_op(doc) do
    doc_len = String.length(doc)
    pos = Enum.random(0..doc_len)
    text = random_string(1..5)

    ops = []
    ops = if pos > 0, do: [pos | ops], else: ops
    ops = [text | ops]
    remaining = doc_len - pos
    ops = if remaining > 0, do: [remaining | ops], else: ops
    Enum.reverse(ops)
  end

  defp random_op(doc) do
    doc_len = String.length(doc)
    if doc_len == 0 do
      [random_string(1..3)]
    else
      # Pick a random position and action
      pos = Enum.random(0..max(doc_len - 1, 0))
      remaining = doc_len - pos

      action = Enum.random([:insert, :delete])

      case action do
        :insert ->
          text = random_string(1..3)
          ops = []
          ops = if pos > 0, do: [pos | ops], else: ops
          ops = [text | ops]
          ops = if remaining > 0, do: [remaining | ops], else: ops
          Enum.reverse(ops)

        :delete ->
          del_len = Enum.random(1..min(remaining, 3))
          remaining_after = remaining - del_len
          ops = []
          ops = if pos > 0, do: [pos | ops], else: ops
          ops = [-del_len | ops]
          ops = if remaining_after > 0, do: [remaining_after | ops], else: ops
          Enum.reverse(ops)
      end
    end
  end
end
