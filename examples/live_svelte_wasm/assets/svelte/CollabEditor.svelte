<script>
  export let initial_doc = "";
  export let initial_version = 0;
  export let client_id = ""; void client_id; // passed from LiveView for OT identity
  export let room_id = "";
  export let live;

  import { onMount, tick } from "svelte";
  import { OTClient, fromDiff, transformCursor } from "../js/ot.js";

  const WASM_MODULE = "live_svelte_wasm_web_markdown";

  let markdown = initial_doc;
  let prevMarkdown = initial_doc;
  let htmlPreview = "";
  let wasmMod = null;
  let wasmReady = false;
  let wasmTimeMs = 0;
  let katexTimeMs = 0;
  let previewEl;
  let textareaEl;
  let katexReady = false;
  let otClient = null;
  let suppressNextInput = false;

  function waitForKatex() {
    return new Promise((resolve) => {
      if (window.renderMathInElement) return resolve();
      const check = setInterval(() => {
        if (window.renderMathInElement) {
          clearInterval(check);
          resolve();
        }
      }, 50);
    });
  }

  onMount(async () => {
    const wasmPromise = (async () => {
      const mod = await import(`/wasm/${WASM_MODULE}/${WASM_MODULE}.js`);
      return await mod.default(`/wasm/${WASM_MODULE}/${WASM_MODULE}_bg.wasm`);
    })();
    const katexPromise = waitForKatex();

    try {
      wasmMod = await wasmPromise;
      wasmReady = true;
    } catch (err) {
      console.error("Failed to load WASM module:", err);
      htmlPreview = "<p>WASM not available. Run <code>mix compile</code> first.</p>";
    }

    await katexPromise;
    katexReady = true;

    // Initialize OT client
    otClient = new OTClient(initial_doc, initial_version, (version, op) => {
      if (live) {
        live.pushEvent("submit_op", { version, op });
      }
    });

    // When a remote op is applied, update the textarea
    otClient.onRemoteOp = (op) => {
      const cursorPos = textareaEl ? textareaEl.selectionStart : 0;
      const cursorEnd = textareaEl ? textareaEl.selectionEnd : 0;

      markdown = otClient.doc;
      prevMarkdown = markdown;

      // Adjust cursor for the remote edit
      tick().then(() => {
        if (textareaEl) {
          const newStart = transformCursor(cursorPos, op);
          const newEnd = transformCursor(cursorEnd, op);
          textareaEl.selectionStart = newStart;
          textareaEl.selectionEnd = newEnd;
        }
      });
    };

    otClient.onResync = (doc) => {
      markdown = doc;
      prevMarkdown = doc;
    };

    // Listen for server events
    if (live) {
      live.handleEvent("ot:ack", ({ version }) => {
        if (otClient) otClient.serverAck(version);
      });

      live.handleEvent("ot:remote_op", ({ version, op }) => {
        if (otClient) otClient.applyServer(op);
      });

      live.handleEvent("ot:resync", ({ doc, version }) => {
        if (otClient) otClient.resync(doc, version);
      });
    }

    if (wasmReady) updatePreview();
  });

  function updatePreview() {
    if (!wasmMod || !markdown) {
      htmlPreview = "";
      return;
    }

    const start = performance.now();

    const encoder = new TextEncoder();
    const inputBytes = encoder.encode(markdown);
    const bufSize = Math.max(inputBytes.length * 4, 4096);
    const ptr = wasmMod.alloc(bufSize);

    const mem = new Uint8Array(wasmMod.memory.buffer, ptr, bufSize);
    mem.fill(0);
    mem.set(inputBytes);

    const resultLen = wasmMod.parse_markdown(ptr, bufSize);

    if (resultLen >= 0) {
      const resultBytes = new Uint8Array(wasmMod.memory.buffer, ptr, resultLen);
      htmlPreview = new TextDecoder().decode(resultBytes);
    } else {
      htmlPreview = "<p><em>Parse error</em></p>";
    }

    wasmMod.dealloc(ptr, bufSize);
    wasmTimeMs = Math.round(performance.now() - start);

    tick().then(() => {
      if (previewEl && window.renderMathInElement) {
        const katexStart = performance.now();
        window.renderMathInElement(previewEl, {
          delimiters: [
            { left: "$$", right: "$$", display: true },
            { left: "$", right: "$", display: false },
            { left: "\\[", right: "\\]", display: true },
            { left: "\\(", right: "\\)", display: false },
          ],
          throwOnError: false,
        });
        katexTimeMs = Math.round(performance.now() - katexStart);
      }
    });
  }

  $: if (wasmMod) {
    markdown;
    updatePreview();
  }

  function onInput() {
    if (!otClient) return;

    const newText = markdown;
    const op = fromDiff(prevMarkdown, newText);

    if (op.length > 0) {
      otClient.applyLocal(op);
      prevMarkdown = newText;
    }
  }
</script>

<div class="editor-container">
  <div class="editor-pane">
    <div class="pane-header">
      <span class="pane-title">Markdown</span>
      <span class="room-badge">Room: {room_id}</span>
      <span class="char-count">{markdown.length} chars</span>
    </div>
    <textarea
      bind:this={textareaEl}
      oninput={onInput}
      bind:value={markdown}
      spellcheck="false"
    ></textarea>
  </div>
  <div class="divider"></div>
  <div class="preview-pane">
    <div class="pane-header">
      <span class="pane-title">Preview</span>
      {#if wasmReady}
        <span class="wasm-badge">WASM {wasmTimeMs}ms</span>
        <span class="katex-badge">KaTeX {katexTimeMs}ms</span>
      {:else}
        <span class="wasm-loading">Loading WASM...</span>
      {/if}
    </div>
    <div class="preview-content" bind:this={previewEl}>{@html htmlPreview}</div>
  </div>
</div>

<style>
  .editor-container {
    display: flex;
    height: calc(100vh - 57px);
    background: #0d1117;
  }

  .editor-pane,
  .preview-pane {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  .divider {
    width: 1px;
    background: #21262d;
  }

  .pane-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.5rem 1rem;
    background: #161b22;
    border-bottom: 1px solid #21262d;
    font-size: 0.8rem;
    flex-shrink: 0;
    gap: 0.5rem;
  }

  .pane-title {
    color: #8b949e;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .room-badge {
    color: #d29922;
    font-size: 0.75rem;
    font-family: monospace;
    background: #d2992220;
    padding: 0.1rem 0.4rem;
    border-radius: 4px;
  }

  .char-count {
    color: #484f58;
    font-size: 0.75rem;
    margin-left: auto;
  }

  .wasm-badge {
    color: #3fb950;
    font-size: 0.75rem;
    font-family: monospace;
  }

  .katex-badge {
    color: #d2a8ff;
    font-size: 0.75rem;
    font-family: monospace;
  }

  .wasm-loading {
    color: #d29922;
    font-size: 0.75rem;
    animation: pulse 1.5s ease-in-out infinite;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
  }

  textarea {
    flex: 1;
    resize: none;
    border: none;
    outline: none;
    padding: 1rem;
    font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace;
    font-size: 0.9rem;
    line-height: 1.6;
    background: #0d1117;
    color: #c9d1d9;
    tab-size: 4;
  }

  textarea::placeholder {
    color: #484f58;
  }

  .preview-content {
    flex: 1;
    overflow-y: auto;
    padding: 1rem;
    font-size: 0.95rem;
    line-height: 1.6;
  }
</style>
