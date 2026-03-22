defmodule MatrixMul.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: MatrixMul.PubSub},
      MatrixMulWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MatrixMul.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
