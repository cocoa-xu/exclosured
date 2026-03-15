defmodule RealtimeSync.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: RealtimeSync.PubSub},
      RealtimeSync.Room,
      RealtimeSyncWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RealtimeSync.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
