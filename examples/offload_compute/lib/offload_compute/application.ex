defmodule OffloadCompute.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: OffloadCompute.PubSub},
      OffloadComputeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: OffloadCompute.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
