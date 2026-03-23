defmodule LiveSvelteWasm.CollabRoomTest do
  use ExUnit.Case, async: false

  alias LiveSvelteWasm.CollabRoom
  alias LiveSvelteWasm.OT

  setup do
    room_id = "test-room-#{System.unique_integer([:positive])}"
    {:ok, room_id: room_id}
  end

  describe "basic operations" do
    test "join returns empty doc at version 0", %{room_id: room_id} do
      {:ok, doc, version} = CollabRoom.join(room_id)
      assert doc == ""
      assert version == 0
    end

    test "submit_op applies operation", %{room_id: room_id} do
      {:ok, "", 0} = CollabRoom.join(room_id)
      {:ok, 1} = CollabRoom.submit_op(room_id, "client-a", 0, ["hello"])
      {:ok, doc, version} = CollabRoom.get_state(room_id)
      assert doc == "hello"
      assert version == 1
    end

    test "sequential ops from same client", %{room_id: room_id} do
      {:ok, "", 0} = CollabRoom.join(room_id)
      {:ok, 1} = CollabRoom.submit_op(room_id, "client-a", 0, ["hello"])
      {:ok, 2} = CollabRoom.submit_op(room_id, "client-a", 1, [5, " world"])
      {:ok, doc, 2} = CollabRoom.get_state(room_id)
      assert doc == "hello world"
    end
  end

  describe "concurrent operations" do
    test "two clients submit concurrently — server transforms", %{room_id: room_id} do
      {:ok, "", 0} = CollabRoom.join(room_id)
      # Set up initial doc
      {:ok, 1} = CollabRoom.submit_op(room_id, "setup", 0, ["hello world"])

      # Client A based on v1: insert " beautiful" after "hello"
      op_a = [5, " beautiful", 6]
      # Client B based on v1: insert "!" at end
      op_b = [11, "!"]

      {:ok, 2} = CollabRoom.submit_op(room_id, "client-a", 1, op_a)
      {:ok, 3} = CollabRoom.submit_op(room_id, "client-b", 1, op_b)

      {:ok, doc, 3} = CollabRoom.get_state(room_id)
      assert doc == "hello beautiful world!"
    end

    test "concurrent deletes converge", %{room_id: room_id} do
      {:ok, "", 0} = CollabRoom.join(room_id)
      {:ok, 1} = CollabRoom.submit_op(room_id, "setup", 0, ["abcdefgh"])

      # Client A: delete "cd" (pos 2, del 2)
      op_a = [2, -2, 4]
      # Client B: delete "ef" (pos 4, del 2)
      op_b = [4, -2, 2]

      {:ok, 2} = CollabRoom.submit_op(room_id, "client-a", 1, op_a)
      {:ok, 3} = CollabRoom.submit_op(room_id, "client-b", 1, op_b)

      {:ok, doc, 3} = CollabRoom.get_state(room_id)
      assert doc == "abgh"
    end

    test "overlapping deletes converge", %{room_id: room_id} do
      {:ok, "", 0} = CollabRoom.join(room_id)
      {:ok, 1} = CollabRoom.submit_op(room_id, "setup", 0, ["abcdefgh"])

      # Client A: delete "bcde"
      op_a = [1, -4, 3]
      # Client B: delete "def"
      op_b = [3, -3, 2]

      {:ok, 2} = CollabRoom.submit_op(room_id, "client-a", 1, op_a)
      {:ok, 3} = CollabRoom.submit_op(room_id, "client-b", 1, op_b)

      {:ok, doc, 3} = CollabRoom.get_state(room_id)
      assert doc == "agh"
    end
  end

  describe "broadcast" do
    test "remote ops are broadcast to subscribers", %{room_id: room_id} do
      Phoenix.PubSub.subscribe(LiveSvelteWasm.PubSub, "collab:#{room_id}")
      {:ok, "", 0} = CollabRoom.join(room_id)
      {:ok, 1} = CollabRoom.submit_op(room_id, "client-a", 0, ["hello"])

      assert_receive {:remote_op, 1, "client-a", ["hello"]}, 1000
    end
  end

  describe "error handling" do
    test "invalid version returns error with resync", %{room_id: room_id} do
      {:ok, "", 0} = CollabRoom.join(room_id)
      {:ok, 1} = CollabRoom.submit_op(room_id, "setup", 0, ["hello"])

      # Submit with version 999 (way ahead)
      result = CollabRoom.submit_op(room_id, "client-a", 999, [5, "!"])
      assert {:error, :invalid_version, "hello", 1} = result
    end
  end
end
