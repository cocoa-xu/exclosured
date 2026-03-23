import Config

config :live_vue_wasm, LiveVueWasmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: LiveVueWasmWeb.ErrorHTML], layout: false],
  pubsub_server: LiveVueWasm.PubSub,
  live_view: [signing_salt: "live_vue_wasm_salt"],
  secret_key_base: String.duplicate("live_vue_wasm_secret", 4),
  http: [port: 4012],
  server: true,
  watchers: [
    npm: ["--silent", "run", "dev", cd: Path.expand("../assets", __DIR__)]
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|wasm)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/live_vue_wasm_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :live_vue,
  vite_host: "http://localhost:5173",
  ssr_module: nil

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
