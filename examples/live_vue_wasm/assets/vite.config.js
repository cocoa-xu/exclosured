import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import liveVuePlugin from "live_vue/vitePlugin";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmRoot = path.resolve(__dirname, "../priv/static/wasm");

// Vite plugin that serves compiled WASM files in dev mode.
// - JS shims: handled via resolveId + load (Vite's module pipeline)
// - .wasm binaries: handled via HTTP middleware (loaded by fetch, not import)
// No hardcoded Phoenix port needed.
function serveWasm() {
  return {
    name: "exclosured-serve-wasm",
    // Tell Vite we can handle /wasm/ module imports
    resolveId(id) {
      if (id.startsWith("/wasm/") && id.endsWith(".js")) {
        const filePath = path.join(wasmRoot, id.slice("/wasm/".length));
        if (fs.existsSync(filePath)) return id;
      }
    },
    // Provide the JS source from priv/static/wasm/
    load(id) {
      if (id.startsWith("/wasm/") && id.endsWith(".js")) {
        const filePath = path.join(wasmRoot, id.slice("/wasm/".length));
        if (fs.existsSync(filePath)) return fs.readFileSync(filePath, "utf-8");
      }
    },
    // Serve .wasm binaries via middleware (they are fetched, not imported)
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

export default defineConfig(({ command }) => {
  return {
    plugins: [vue(), liveVuePlugin(), serveWasm()],
    build: {
      outDir: "../priv/static/assets",
      emptyOutDir: true,
      rollupOptions: {
        input: "js/app.js",
        output: { entryFileNames: "app.js" },
        external: [/^\/wasm\//],
      },
    },
    resolve: {
      dedupe: ["vue", "phoenix", "phoenix_html", "phoenix_live_view"],
    },
  };
});
