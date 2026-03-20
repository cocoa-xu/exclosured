defmodule TypedEventsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :typed_events

  @session_options [
    store: :cookie,
    key: "_typed_events_key",
    signing_salt: "typed_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :typed_events,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TypedEventsWeb.Router
end
