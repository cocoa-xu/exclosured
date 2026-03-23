import Config

config :canvas_demo, CanvasDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: CanvasDemoWeb.ErrorHTML], layout: false],
  pubsub_server: CanvasDemo.PubSub,
  live_view: [signing_salt: "canvas_dev_salt"],
  secret_key_base: String.duplicate("canvas_dev_secret", 4),
  http: [port: 4002],
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:canvas_demo, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/canvas_demo_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :esbuild,
  version: "0.25.0",
  canvas_demo: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :exclosured,
  modules: [
    renderer: [canvas: true]
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
