defmodule StreamingDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: StreamingDemo.PubSub},
      StreamingDemoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: StreamingDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
