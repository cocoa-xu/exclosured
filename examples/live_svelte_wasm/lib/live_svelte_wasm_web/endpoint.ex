defmodule LiveSvelteWasmWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :live_svelte_wasm

  @session_options [
    store: :cookie,
    key: "_live_svelte_wasm_key",
    signing_salt: "svelte_wasm_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :live_svelte_wasm,
    gzip: false,
    only: ~w(wasm assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LiveSvelteWasmWeb.Router
end
