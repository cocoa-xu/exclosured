defmodule LiveVueWasm.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: LiveVueWasm.PubSub},
      LiveVueWasmWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LiveVueWasm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
