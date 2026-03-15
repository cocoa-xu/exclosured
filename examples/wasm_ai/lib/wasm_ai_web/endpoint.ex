defmodule WasmAiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :wasm_ai

  @session_options [
    store: :cookie,
    key: "_wasm_ai_key",
    signing_salt: "wasm_ai_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :wasm_ai,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug WasmAiWeb.Router
end
