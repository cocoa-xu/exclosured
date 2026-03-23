import Config

# In production, disable watchers. Assets are pre-built by `node build.js`.
config :live_svelte_wasm, LiveSvelteWasmWeb.Endpoint,
  watchers: []
