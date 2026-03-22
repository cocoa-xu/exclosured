# LiveVue + Exclosured WASM: Real-time Statistics Dashboard

A real-time statistics dashboard that demonstrates LiveVue and Exclosured
working together. LiveView pushes simulated sensor data, a Vue component
renders a live line chart, and WASM (compiled inline from Rust via `defwasm`)
computes rolling statistics entirely in the browser.

## Architecture

```
LiveView (Elixir)          Vue Component (Browser)           WASM (Rust)
 +------------------+      +-------------------------+      +-----------------+
 | Timer: 500ms     | ---> | StatsChart.vue          | ---> | compute_stats() |
 | Push data points |      | - Receives props.data   |      | - Parse JSON    |
 |                  |      | - Calls WASM on change   |      | - mean, min,    |
 |                  |      | - Draws canvas chart     | <--- |   max, stddev,  |
 |                  |      | - Shows stats panel      |      |   p50, p90, p99 |
 +------------------+      +-------------------------+      +-----------------+
```

- **LiveView** generates a new random sensor reading every 500ms (sine wave + noise)
- **LiveVue** passes data as a JSON-encoded prop to the Vue component
- **Vue** watches for prop changes, sends the full data array to WASM, and renders results
- **WASM** (`defwasm` inline Rust) computes count, mean, min, max, std_dev, p50, p90, p99
- The chart and stats panel update only after WASM finishes loading

## Prerequisites

- Elixir 1.15+
- Node.js 18+ and npm
- Rust toolchain with `wasm32-unknown-unknown` target
- `wasm-bindgen-cli`: `cargo install wasm-bindgen-cli`

## Running

```bash
mix setup        # deps.get + npm install + vite build
mix phx.server
```

Then open [http://localhost:4012](http://localhost:4012).

## Key Files

| File | Purpose |
|------|---------|
| `lib/live_vue_wasm_web/stats.ex` | Inline WASM module using `defwasm` |
| `lib/live_vue_wasm_web/live/dashboard_live.ex` | LiveView with timer and data generation |
| `assets/vue/StatsChart.vue` | Vue component: chart rendering + WASM calls |
| `assets/vite.config.js` | Vite plugin for serving WASM in dev mode |
| `assets/js/app.js` | LiveSocket setup with LiveVue hooks |

## Notes on Integrating LiveVue with WASM

### 1. Serving WASM files through Vite's dev server

In dev mode, Vue components are served by Vite (port 5173), while WASM
files are compiled into `priv/static/wasm/` by Exclosured. When a Vue
component calls `import("/wasm/...")`, the browser resolves this relative
to Vite's origin, not Phoenix. So the WASM files must be available on
Vite's dev server.

**What does NOT work:**

- **`server.proxy`** to Phoenix: requires hardcoding the Phoenix port.
- **`publicDir: "../priv/static"`**: Vite explicitly blocks `import()` of
  files from `publicDir` with the error _"should not be imported from
  source code. It can only be referenced via HTML tags."_
- **HTTP middleware** via `configureServer`: handles `fetch()` requests
  fine, but `import()` goes through Vite's module pipeline which does
  not call the middleware for JS module resolution.

**What works: a Vite plugin with `resolveId` + `load` hooks.**

JS shims (loaded via `import()`) must be handled through Vite's module
resolution system. Binary `.wasm` files (loaded via `fetch()` inside the
shim) can be served through HTTP middleware. This example uses a plugin
called `serveWasm()` in `vite.config.js` that does both:

```javascript
function serveWasm() {
  const wasmRoot = path.resolve(__dirname, "../priv/static/wasm");
  return {
    name: "exclosured-serve-wasm",
    // JS shims: hook into Vite's module pipeline
    resolveId(id) {
      if (id.startsWith("/wasm/") && id.endsWith(".js")) {
        const filePath = path.join(wasmRoot, id.slice("/wasm/".length));
        if (fs.existsSync(filePath)) return id;
      }
    },
    load(id) {
      if (id.startsWith("/wasm/") && id.endsWith(".js")) {
        const filePath = path.join(wasmRoot, id.slice("/wasm/".length));
        if (fs.existsSync(filePath)) return fs.readFileSync(filePath, "utf-8");
      }
    },
    // .wasm binaries: serve via HTTP middleware
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = req.url?.split("?")[0];
        if (!url?.startsWith("/wasm/") || !url.endsWith(".wasm")) return next();
        const filePath = path.join(wasmRoot, url.slice("/wasm/".length));
        if (!fs.existsSync(filePath)) return next();
        res.setHeader("Content-Type", "application/wasm");
        res.end(fs.readFileSync(filePath));
      });
    },
  };
}
```

In production builds, `/wasm/` paths are externalized via
`rollupOptions.external` so Rollup does not try to bundle them. Phoenix
serves them via `Plug.Static` at runtime.

### 2. `import()` must use a variable, not a string literal

Even with `/* @vite-ignore */`, Vite still resolves string literals and
template literals inside `import()`. Only a plain variable reference is
opaque to Vite's static analysis:

```javascript
// FAILS - Vite resolves string literals regardless of @vite-ignore:
const mod = await import(/* @vite-ignore */ "/wasm/my_module/my_module.js");

// FAILS - Vite can still analyze template literals inside import():
const mod = await import(/* @vite-ignore */ `/wasm/${name}/${name}.js`);

// WORKS - a plain variable is opaque to static analysis:
const wasmJsUrl = `/wasm/${name}/${name}.js`;
const mod = await import(/* @vite-ignore */ wasmJsUrl);
```

### 3. WASM buffer must be large enough for the result

`defwasm` functions with `:binary` args reuse the same buffer for input
and output. The second parameter tells Rust how large the buffer is. If
you pass only the input length, the output (which is often much larger)
will write past the end and trigger a WASM `unreachable` trap.

Always allocate generously, zero the buffer (since `alloc` returns
uninitialized memory), and pass the full buffer size:

```javascript
const bufLen = Math.max(encoded.length * 2, 1024);
const ptr = wasm.alloc(bufLen);
const mem = new Uint8Array(wasm.memory.buffer, ptr, bufLen);
mem.fill(0);       // alloc returns uninitialized memory
mem.set(encoded);  // write input at the start
const resultLen = wasm.compute_stats(ptr, bufLen);  // full size, not input size
```

### 4. Disable SSR with `nil`, not a module name

LiveVue 0.7+ disables SSR by setting `ssr_module` to `nil`:

```elixir
config :live_vue, ssr_module: nil
```

`LiveVue.SSR.None` does not exist. Using it causes a runtime
`UndefinedFunctionError`.

### 5. Push events to LiveView via `useLiveVue()`

LiveVue does not pass a `live` prop to Vue components. It uses Vue's
`provide`/`inject` system. Use the `useLiveVue()` composable:

```javascript
import { useLiveVue } from "live_vue";

const live = useLiveVue();  // must be called at top level of <script setup>

// After WASM loads:
live.pushEvent("wasm:ready", {});
```

This is also how you send any other event back to the LiveView from
within a Vue component.
