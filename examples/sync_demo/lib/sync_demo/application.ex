defmodule SyncDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: SyncDemo.PubSub},
      SyncDemoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SyncDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
