defmodule PrivateAnalyticsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :private_analytics

  @session_options [
    store: :cookie,
    key: "_private_analytics_key",
    signing_salt: "private_analytics_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      max_frame_size: 5_000_000
    ]

  plug Plug.Static,
    at: "/",
    from: :private_analytics,
    gzip: false,
    only: ~w(wasm assets sample_data.csv)

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PrivateAnalyticsWeb.Router
end
