import Config

config :wasm_ai, WasmAiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: WasmAiWeb.ErrorHTML], layout: false],
  pubsub_server: WasmAi.PubSub,
  live_view: [signing_salt: "wasm_ai_dev_salt"],
  secret_key_base: String.duplicate("wasm_ai_dev_secret", 4),
  http: [port: 4001],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:wasm_ai, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/wasm_ai_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  wasm_ai: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    text_engine: []
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
