defmodule BrotliCompressWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :brotli_compress

  @session_options [
    store: :cookie,
    key: "_brotli_compress_key",
    signing_salt: "brotli_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :brotli_compress,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BrotliCompressWeb.Router
end
