defmodule PrivateAnalytics.RoomTest do
  use ExUnit.Case

  alias PrivateAnalytics.Room

  @viewer_hash "viewer_token_hash_123"
  @editor_hash "editor_token_hash_456"

  setup do
    room_id = "test_room_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Room.create(room_id, self(), @viewer_hash, @editor_hash)
    %{room_id: room_id}
  end

  describe "create/4" do
    test "creates a room successfully" do
      room_id = "new_room_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Room.create(room_id, self(), "vh", "eh")
      assert Process.alive?(pid)
    end
  end

  describe "join/3" do
    test "owner can join their own room", %{room_id: room_id} do
      assert {:ok, :owner} = Room.join(room_id, self(), "")
    end

    test "viewer can join with correct token", %{room_id: room_id} do
      viewer_pid = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, :viewer} = Room.join(room_id, viewer_pid, @viewer_hash)
    end

    test "editor can join with correct token", %{room_id: room_id} do
      editor_pid = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, :editor} = Room.join(room_id, editor_pid, @editor_hash)
    end

    test "rejects invalid token", %{room_id: room_id} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert {:error, :invalid_token} = Room.join(room_id, pid, "wrong_token")
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = Room.join("nonexistent", self(), "token")
    end

    test "sends current view to new viewer on join", %{room_id: room_id} do
      # Store a view first
      Room.broadcast_view(room_id, "encrypted_view_data")
      # Allow the cast to process
      Process.sleep(50)

      # Join as viewer from a separate process
      test_pid = self()

      spawn(fn ->
        result = Room.join(room_id, self(), @viewer_hash)
        send(test_pid, {:join_result, result})
        # Wait for the view_update message
        receive do
          {:view_update, data} -> send(test_pid, {:got_view, data})
        after
          500 -> send(test_pid, :no_view)
        end
      end)

      assert_receive {:join_result, {:ok, :viewer}}, 1000
      assert_receive {:got_view, "encrypted_view_data"}, 1000
    end

    test "sends current schema to new viewer on join", %{room_id: room_id} do
      Room.broadcast_schema(room_id, "encrypted_schema_data")
      Process.sleep(50)

      test_pid = self()

      spawn(fn ->
        Room.join(room_id, self(), @viewer_hash)

        receive do
          {:schema_update, data} -> send(test_pid, {:got_schema, data})
        after
          500 -> send(test_pid, :no_schema)
        end
      end)

      assert_receive {:got_schema, "encrypted_schema_data"}, 1000
    end
  end

  describe "broadcast_view/2" do
    test "stores view for late joiners", %{room_id: room_id} do
      Room.broadcast_view(room_id, "test_view_data")
      Process.sleep(50)

      {:ok, state} = Room.get_state(room_id)
      assert state.current_view == "test_view_data"
    end

    test "sends view to connected viewers", %{room_id: room_id} do
      test_pid = self()

      viewer_pid =
        spawn(fn ->
          Room.join(room_id, self(), @viewer_hash)
          # Drain the initial messages (if any)
          receive do
            _ -> :ok
          after
            100 -> :ok
          end

          # Wait for the broadcast
          receive do
            {:view_update, data} -> send(test_pid, {:viewer_got, data})
          after
            1000 -> send(test_pid, :timeout)
          end
        end)

      Process.sleep(100)
      Room.broadcast_view(room_id, "new_results")

      assert_receive {:viewer_got, "new_results"}, 1000
    end
  end

  describe "broadcast_schema/2" do
    test "stores schema for late joiners", %{room_id: room_id} do
      Room.broadcast_schema(room_id, "schema_data")
      Process.sleep(50)

      {:ok, state} = Room.get_state(room_id)
      assert state.current_schema == "schema_data"
    end
  end

  describe "submit_query/3" do
    test "relays query from editor to owner", %{room_id: room_id} do
      editor_pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, :editor} = Room.join(room_id, editor_pid, @editor_hash)

      Room.submit_query(room_id, editor_pid, "SELECT * FROM data")

      assert_receive {:query_request, "SELECT * FROM data", ^editor_pid}, 1000
    end

    test "rejects query from viewer", %{room_id: room_id} do
      viewer_pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, :viewer} = Room.join(room_id, viewer_pid, @viewer_hash)

      Room.submit_query(room_id, viewer_pid, "SELECT * FROM data")

      refute_receive {:query_request, _, _}, 200
    end
  end

  describe "get_state/1" do
    test "returns room state", %{room_id: room_id} do
      {:ok, state} = Room.get_state(room_id)
      assert state.id == room_id
      assert state.owner_connected == true
      assert state.viewer_count == 0
    end

    test "includes current view and schema data", %{room_id: room_id} do
      Room.broadcast_view(room_id, "view123")
      Room.broadcast_schema(room_id, "schema456")
      Process.sleep(50)

      {:ok, state} = Room.get_state(room_id)
      assert state.current_view == "view123"
      assert state.current_schema == "schema456"
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = Room.get_state("nonexistent")
    end
  end

  describe "rate limiting" do
    test "allows broadcasts under the limit", %{room_id: room_id} do
      for i <- 1..5 do
        Room.broadcast_view(room_id, "data_#{i}")
      end

      Process.sleep(50)
      {:ok, state} = Room.get_state(room_id)
      assert state.current_view == "data_5"
    end
  end

  describe "leave/2" do
    test "removes viewer from room", %{room_id: room_id} do
      viewer_pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, :viewer} = Room.join(room_id, viewer_pid, @viewer_hash)

      {:ok, state_before} = Room.get_state(room_id)
      assert state_before.viewer_count == 1

      Room.leave(room_id, viewer_pid)
      Process.sleep(50)

      {:ok, state_after} = Room.get_state(room_id)
      assert state_after.viewer_count == 0
    end
  end
end
