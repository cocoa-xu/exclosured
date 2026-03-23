import Config

config :live_svelte_wasm, LiveSvelteWasmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: LiveSvelteWasmWeb.ErrorHTML], layout: false],
  pubsub_server: LiveSvelteWasm.PubSub,
  live_view: [signing_salt: "svelte_wasm_dev_salt"],
  secret_key_base: String.duplicate("svelte_wasm_dev_secret_", 4),
  http: [port: 4013],
  server: true,
  watchers: [
    node: ["build.js", "--watch", cd: Path.expand("../assets", __DIR__)]
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"priv/static/wasm/.*(wasm|js)$",
      ~r"lib/live_svelte_wasm_web/(live|components)/.*(ex|heex)$",
      ~r"assets/svelte/.*(svelte)$"
    ]
  ]

config :logger, level: :info
config :phoenix, :json_library, Jason

config :mime, :types, %{"wasm" => ["application/wasm"]}
