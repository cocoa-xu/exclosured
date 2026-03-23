import Config

config :sync_demo, SyncDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: SyncDemoWeb.ErrorHTML], layout: false],
  pubsub_server: SyncDemo.PubSub,
  live_view: [signing_salt: "sync_dev_salt"],
  secret_key_base: String.duplicate("sync_demo_dev_secret", 4),
  http: [port: 4008],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:sync_demo, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/sync_demo_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  sync_demo: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    visualizer: [canvas: true]
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
