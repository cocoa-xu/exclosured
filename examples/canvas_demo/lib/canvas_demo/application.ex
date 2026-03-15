defmodule CanvasDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: CanvasDemo.PubSub},
      CanvasDemoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CanvasDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
