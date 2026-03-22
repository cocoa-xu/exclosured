import Config

config :private_analytics, PrivateAnalyticsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: PrivateAnalyticsWeb.ErrorHTML], layout: false],
  pubsub_server: PrivateAnalytics.PubSub,
  live_view: [signing_salt: "private_analytics_dev_salt"],
  secret_key_base: String.duplicate("private_analytics_dev_secret", 4),
  http: [port: 4011],
  server: true,
  watchers: [
    esbuild:
      {Esbuild, :install_and_run,
       [:private_analytics, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/private_analytics_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  private_analytics: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    private_analytics_wasm: []
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
