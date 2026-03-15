defmodule CanvasDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :canvas_demo

  @session_options [
    store: :cookie,
    key: "_canvas_demo_key",
    signing_salt: "canvas_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :canvas_demo,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug CanvasDemoWeb.Router
end
