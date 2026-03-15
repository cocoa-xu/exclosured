import Config

config :racing_game, RacingGameWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: RacingGameWeb.ErrorHTML], layout: false],
  pubsub_server: RacingGame.PubSub,
  live_view: [signing_salt: "racing_dev_salt"],
  secret_key_base: String.duplicate("racing_dev_secret_", 4),
  http: [port: 4004],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:racing_game, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/racing_game_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  racing_game: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    race_client: [mode: :compute]
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason
