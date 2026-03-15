defmodule RacingGame.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: RacingGame.PubSub},
      RacingGame.Room,
      RacingGameWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RacingGame.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
