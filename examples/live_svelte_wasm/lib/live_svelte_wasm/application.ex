defmodule LiveSvelteWasm.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: LiveSvelteWasm.PubSub},
      LiveSvelteWasmWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LiveSvelteWasm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
