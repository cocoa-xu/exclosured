defmodule RacingGameWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :racing_game

  @session_options [
    store: :cookie,
    key: "_racing_game_key",
    signing_salt: "racing_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :racing_game,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug RacingGameWeb.Router
end
