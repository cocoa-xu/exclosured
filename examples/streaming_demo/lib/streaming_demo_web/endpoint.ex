defmodule StreamingDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :streaming_demo

  @session_options [
    store: :cookie,
    key: "_streaming_demo_key",
    signing_salt: "streaming_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :streaming_demo,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug StreamingDemoWeb.Router
end
