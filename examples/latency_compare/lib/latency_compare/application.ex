defmodule LatencyCompare.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: LatencyCompare.PubSub},
      LatencyCompareWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LatencyCompare.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
