defmodule PrivateAnalytics.RoomRegistry do
  @moduledoc """
  Wraps the Registry used for room process lookup.
  Provides convenience functions for finding room GenServer processes by room ID.
  """

  @registry __MODULE__

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Look up a room process by its ID.
  Returns {:ok, pid} if found, :error otherwise.
  """
  def lookup(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns the via tuple for registering or calling a room process.
  """
  def via(room_id) do
    {:via, Registry, {@registry, room_id}}
  end
end
