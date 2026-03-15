defmodule RealtimeSync.Room do
  @moduledoc """
  Shared room state. Holds the latest image snapshot (compressed)
  and a log of drawing operations applied since that snapshot.

  New joiners receive the snapshot + ops to reconstruct the current state.
  Filters bake into a new snapshot and clear the ops list.
  """

  use Agent

  @topic "collab:room"

  def start_link(_opts) do
    Agent.start_link(fn -> %{image: nil, ops: []} end, name: __MODULE__)
  end

  def get_state do
    Agent.get(__MODULE__, & &1)
  end

  def set_image(compressed_data) do
    Agent.update(__MODULE__, fn _ -> %{image: compressed_data, ops: []} end)
    Phoenix.PubSub.broadcast(RealtimeSync.PubSub, @topic, :state_updated)
  end

  def add_op(op) do
    Agent.update(__MODULE__, fn state ->
      %{state | ops: state.ops ++ [op]}
    end)
  end

  def bake_snapshot(compressed_data) do
    Agent.update(__MODULE__, fn _ -> %{image: compressed_data, ops: []} end)
  end
end
