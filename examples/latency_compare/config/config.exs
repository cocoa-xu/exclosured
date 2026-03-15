import Config

config :latency_compare, LatencyCompareWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: LatencyCompareWeb.ErrorHTML], layout: false],
  pubsub_server: LatencyCompare.PubSub,
  live_view: [signing_salt: "latency_dev_salt"],
  secret_key_base: String.duplicate("latency_dev_secret", 4),
  http: [port: 4007],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:latency_compare, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/latency_compare_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  latency_compare: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    image_filter: [mode: :compute]
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason
