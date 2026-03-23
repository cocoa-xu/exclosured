import Config

config :brotli_compress, BrotliCompressWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: BrotliCompressWeb.ErrorHTML], layout: false],
  pubsub_server: BrotliCompress.PubSub,
  live_view: [signing_salt: "brotli_dev_salt"],
  secret_key_base: String.duplicate("brotli_dev_secret_key", 4),
  http: [port: 4014],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:brotli_compress, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/brotli_compress_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  brotli_compress: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
