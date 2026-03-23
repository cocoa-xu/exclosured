import Config

# In production, disable Vite dev server and watchers.
# Assets are pre-built by `npx vite build`.
config :live_vue_wasm, LiveVueWasmWeb.Endpoint,
  watchers: []

config :live_vue,
  vite_host: nil
