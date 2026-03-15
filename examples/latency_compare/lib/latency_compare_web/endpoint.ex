defmodule LatencyCompareWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :latency_compare

  @session_options [
    store: :cookie,
    key: "_latency_compare_key",
    signing_salt: "latency_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :latency_compare,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LatencyCompareWeb.Router
end
