defmodule TypedEvents.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: TypedEvents.PubSub},
      TypedEventsWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: TypedEvents.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
