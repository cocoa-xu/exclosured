defmodule PrivateAnalytics.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: PrivateAnalytics.PubSub},
      {Registry, keys: :unique, name: PrivateAnalytics.RoomRegistry},
      {DynamicSupervisor, name: PrivateAnalytics.RoomSupervisor, strategy: :one_for_one},
      PrivateAnalyticsWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: PrivateAnalytics.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
