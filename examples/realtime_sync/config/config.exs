import Config

config :realtime_sync, RealtimeSyncWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: RealtimeSyncWeb.ErrorHTML], layout: false],
  pubsub_server: RealtimeSync.PubSub,
  live_view: [signing_salt: "realtime_dev_salt"],
  secret_key_base: String.duplicate("realtime_dev_secret", 4),
  http: [port: 4003],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:realtime_sync, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/realtime_sync_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  realtime_sync: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    sync_client: []
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason
