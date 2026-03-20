import Config

config :typed_events, TypedEventsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: TypedEventsWeb.ErrorHTML], layout: false],
  pubsub_server: TypedEvents.PubSub,
  live_view: [signing_salt: "typed_events_salt"],
  secret_key_base: String.duplicate("typed_events_dev_secret", 4),
  http: [port: 4010],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:typed_events, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/typed_events_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  typed_events: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    pipeline: []
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason
