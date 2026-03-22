defmodule LiveVueWasmWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :live_vue_wasm

  @session_options [
    store: :cookie,
    key: "_live_vue_wasm_key",
    signing_salt: "vue_wasm_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :live_vue_wasm,
    gzip: false,
    only: ~w(wasm assets)

  # Serve Vite dev assets in development
  plug Plug.Static,
    at: "/assets",
    from: {:live_vue_wasm, "priv/static/assets"},
    gzip: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LiveVueWasmWeb.Router
end
