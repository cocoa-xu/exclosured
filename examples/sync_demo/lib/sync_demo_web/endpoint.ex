defmodule SyncDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :sync_demo

  @session_options [
    store: :cookie,
    key: "_sync_demo_key",
    signing_salt: "sync_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :sync_demo,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SyncDemoWeb.Router
end
