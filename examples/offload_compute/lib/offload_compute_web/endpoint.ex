defmodule OffloadComputeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :offload_compute

  @session_options [
    store: :cookie,
    key: "_offload_compute_key",
    signing_salt: "offload_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :offload_compute,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug OffloadComputeWeb.Router
end
