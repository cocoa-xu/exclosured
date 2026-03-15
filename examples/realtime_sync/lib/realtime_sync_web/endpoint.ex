defmodule RealtimeSyncWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :realtime_sync

  @session_options [
    store: :cookie,
    key: "_realtime_sync_key",
    signing_salt: "realtime_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 5_000_000]

  plug Plug.Static,
    at: "/",
    from: :realtime_sync,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug RealtimeSyncWeb.Router
end
