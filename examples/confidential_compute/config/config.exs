import Config

config :confidential_compute, ConfidentialComputeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: ConfidentialComputeWeb.ErrorHTML], layout: false],
  pubsub_server: ConfidentialCompute.PubSub,
  live_view: [signing_salt: "confidential_dev_salt"],
  secret_key_base: String.duplicate("confidential_dev_secret", 4),
  http: [port: 4006],
  server: true,
  watchers: [
    esbuild:
      {Esbuild, :install_and_run,
       [:confidential_compute, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/confidential_compute_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  confidential_compute: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
