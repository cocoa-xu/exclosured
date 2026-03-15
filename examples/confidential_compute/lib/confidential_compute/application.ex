defmodule ConfidentialCompute.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ConfidentialCompute.PubSub},
      ConfidentialComputeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ConfidentialCompute.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
