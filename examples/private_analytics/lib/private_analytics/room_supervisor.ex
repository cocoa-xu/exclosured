defmodule PrivateAnalytics.RoomSupervisor do
  @moduledoc """
  DynamicSupervisor for starting and managing Room GenServers.
  Each room is started as a temporary child that will not be restarted on crash.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
