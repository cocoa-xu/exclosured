import Config

config :matrix_mul, MatrixMulWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: MatrixMulWeb.ErrorHTML], layout: false],
  pubsub_server: MatrixMul.PubSub,
  live_view: [signing_salt: "matrix_dev_salt"],
  secret_key_base: String.duplicate("matrix_dev_secret_key_", 4),
  http: [port: 4015],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:matrix_mul, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/matrix_mul_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  matrix_mul: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
