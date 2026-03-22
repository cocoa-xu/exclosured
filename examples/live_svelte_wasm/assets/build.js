// Build script for esbuild with Svelte 5 plugin support.
// LiveSvelte requires esbuild-svelte to compile .svelte files,
// which needs the programmatic esbuild API (plugins are not
// available through the CLI).

import esbuild from "esbuild";
import sveltePlugin from "esbuild-svelte";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const isWatch = process.argv.includes("--watch");

const buildOptions = {
  entryPoints: ["js/app.js"],
  bundle: true,
  target: "es2020",
  outdir: "../priv/static/assets",
  external: ["/fonts/*", "/images/*", "/wasm/*"],
  sourcemap: isWatch ? "inline" : false,
  plugins: [
    sveltePlugin({
      compilerOptions: { css: "injected" },
    }),
  ],
  logLevel: "info",
  nodePaths: [
    path.resolve(__dirname, "../deps"),
    path.resolve(__dirname, "node_modules"),
  ],
};

async function run() {
  if (isWatch) {
    const ctx = await esbuild.context(buildOptions);
    await ctx.watch();
    console.log("Watching for changes...");
  } else {
    await esbuild.build(buildOptions);
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
