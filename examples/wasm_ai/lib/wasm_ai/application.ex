defmodule WasmAi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: WasmAi.PubSub},
      WasmAiWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: WasmAi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
