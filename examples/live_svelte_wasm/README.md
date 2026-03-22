# LiveSvelte + Exclosured WASM: Markdown Editor with Math

A split-pane Markdown editor with live math rendering, showcasing four
technologies working together:

- **Elixir** (Phoenix LiveView) manages editor state and syncs between users
- **Svelte** (LiveSvelte) renders the split-pane editor UI
- **Rust** (pulldown-cmark via `defwasm`) parses markdown to HTML in WebAssembly
- **JavaScript** (KaTeX) renders LaTeX math expressions from the HTML output

## Architecture

```
Keystroke
  |
  v
Svelte Component ──> WASM (pulldown-cmark) ──> HTML string
  |                                               |
  |                                               v
  |                                         KaTeX auto-render
  |                                               |
  v                                               v
LiveView (state sync)                    Preview pane (with math)
```

Every keystroke triggers:
1. WASM parses markdown to HTML (sub-millisecond, Rust)
2. Svelte updates the preview DOM
3. KaTeX scans the preview and renders `$...$` / `$$...$$` math expressions

## Prerequisites

- Elixir 1.15+
- Node.js 18+ and npm
- Rust with `wasm32-unknown-unknown` target: `rustup target add wasm32-unknown-unknown`
- `wasm-bindgen-cli`: `cargo install wasm-bindgen-cli`

## Running

```bash
mix setup        # deps.get + npm install + esbuild
mix phx.server
```

Open [http://localhost:4013](http://localhost:4013).

## Math Syntax

Inline math with single dollars: `$x^2 + y^2 = r^2$`

Display math with double dollars:

```
$$\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}$$
```

Also supports `\(...\)` for inline and `\[...\]` for display math.

## Key Files

| File | Purpose |
|------|---------|
| `lib/live_svelte_wasm_web/markdown.ex` | Inline WASM with `pulldown-cmark` dep |
| `lib/live_svelte_wasm_web/live/editor_live.ex` | LiveView with default markdown + math examples |
| `assets/svelte/MarkdownEditor.svelte` | Split-pane editor, WASM calls, KaTeX rendering |
| `assets/build.js` | esbuild config with Svelte 5 plugin |

## Notes

### Svelte 5 compatibility

`live_svelte >= 0.15` requires Svelte 5. The `package.json` uses
`svelte: "^5.0.0"` and `esbuild-svelte: "^0.9.0"`. The old
`svelte-preprocess` package is no longer needed.

esbuild needs `node_modules` in `nodePaths` so that imports from
`../deps/live_svelte/` can resolve `svelte`:

```javascript
nodePaths: [
  path.resolve(__dirname, "../deps"),
  path.resolve(__dirname, "node_modules"),
],
```

### WASM exports are on the init return value

The wasm-bindgen `init()` function (default export) returns the raw WASM
exports. Store that, not the JS module:

```javascript
const mod = await import("/wasm/my_module/my_module.js");
// Correct: wasmMod has alloc, dealloc, parse_markdown, memory
const wasmMod = await mod.default("/wasm/my_module/my_module_bg.wasm");
// Wrong: mod is the JS wrapper, it does NOT have alloc/parse_markdown
```

### Buffer zeroing

`alloc` returns uninitialized memory. Zero the buffer before writing
input, and pass the full buffer size (not the input size) so Rust has
room to write the larger HTML output:

```javascript
const bufSize = Math.max(inputBytes.length * 4, 4096);
const ptr = wasmMod.alloc(bufSize);
const mem = new Uint8Array(wasmMod.memory.buffer, ptr, bufSize);
mem.fill(0);
mem.set(inputBytes);
const resultLen = wasmMod.parse_markdown(ptr, bufSize);
```
