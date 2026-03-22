defmodule MatrixMulWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :matrix_mul

  @session_options [
    store: :cookie,
    key: "_matrix_mul_key",
    signing_salt: "matrix_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :matrix_mul,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MatrixMulWeb.Router
end
