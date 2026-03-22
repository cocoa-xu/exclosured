import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// ---------- WASM module loading ----------

let wasmMod = null;

async function loadWasm() {
  const statusEl = document.getElementById("wasm-status");
  try {
    const name = "brotli_compress_web_compressor";
    const jsUrl = `/wasm/${name}/${name}.js`;
    const wasmUrl = `/wasm/${name}/${name}_bg.wasm`;
    const mod = await import(jsUrl);
    wasmMod = await mod.default(wasmUrl);
    if (statusEl) {
      statusEl.textContent = "WASM Ready";
      statusEl.className = "badge badge-ready";
    }
  } catch (err) {
    console.error("Failed to load WASM module:", err);
    if (statusEl) {
      statusEl.textContent = "WASM Error";
    }
  }
}

// ---------- Gzip compression via CompressionStream ----------

async function gzipCompress(data) {
  const cs = new CompressionStream("gzip");
  const writer = cs.writable.getWriter();
  writer.write(data);
  writer.close();
  const reader = cs.readable.getReader();
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  const totalLength = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

// ---------- Brotli compression via WASM ----------

function getQuality() {
  const slider = document.getElementById("quality-slider");
  return slider ? parseInt(slider.value) : 4;
}

function brotliCompress(data) {
  if (!wasmMod) return null;

  // Buffer layout: [4 bytes LE length] [data...] [space for output]
  const bufSize = 4 + data.length + Math.max(data.length, 4096);
  const ptr = wasmMod.alloc(bufSize);
  const mem = new Uint8Array(wasmMod.memory.buffer, ptr, bufSize);

  // Write input length as little-endian u32 in first 4 bytes
  const len = data.length;
  mem[0] = len & 0xff;
  mem[1] = (len >> 8) & 0xff;
  mem[2] = (len >> 16) & 0xff;
  mem[3] = (len >> 24) & 0xff;
  // Write data starting at byte 4
  mem.set(data, 4);

  const quality = getQuality();
  const resultLen = wasmMod.compress(ptr, bufSize, quality);

  let compressed = null;
  if (resultLen > 0) {
    compressed = new Uint8Array(wasmMod.memory.buffer, ptr, resultLen).slice();
  }

  wasmMod.dealloc(ptr, bufSize);
  return compressed;
}

// ---------- Formatting helpers ----------

function formatBytes(bytes) {
  if (bytes === 0) return "0 bytes";
  if (bytes === 1) return "1 byte";
  if (bytes < 1024) return bytes.toLocaleString() + " bytes";
  return (bytes / 1024).toFixed(1) + " KB";
}

function formatRatio(originalSize, compressedSize) {
  if (originalSize === 0) return "0%";
  const ratio = ((1 - compressedSize / originalSize) * 100).toFixed(1);
  return ratio + "%";
}

function formatTime(ms) {
  if (ms < 1) return ms.toFixed(3) + " ms";
  return ms.toFixed(1) + " ms";
}

// ---------- UI rendering ----------

function renderStats(containerId, stats, type) {
  const container = document.getElementById(containerId);
  if (!container) return;

  const valueClass = type === "gzip" ? "stat-value-gzip" : "stat-value-brotli";
  const barClass = type === "gzip" ? "bar-fill-gzip" : "bar-fill-brotli";
  const barWidth = stats.originalSize > 0
    ? ((stats.compressedSize / stats.originalSize) * 100).toFixed(1)
    : "0";

  container.innerHTML = `
    <div class="stat-row">
      <span class="stat-label">Compressed size</span>
      <span class="stat-value ${valueClass}">${formatBytes(stats.compressedSize)}</span>
    </div>
    <div class="stat-row">
      <span class="stat-label">Reduction</span>
      <span class="stat-value ${valueClass}">${formatRatio(stats.originalSize, stats.compressedSize)}</span>
    </div>
    <div class="stat-row">
      <span class="stat-label">Time</span>
      <span class="stat-value ${valueClass}">${formatTime(stats.timeMs)}</span>
    </div>
    <div class="stat-row">
      <span class="stat-label">Available in</span>
      <span class="stat-value" style="color:#888;font-size:0.8rem;">${stats.availability}</span>
    </div>
    <div class="bar-container">
      <div class="bar-fill ${barClass}" style="width:${barWidth}%"></div>
    </div>
    <div class="bar-label">${barWidth}% of original</div>
  `;
}

function updateWinner(gzipSize, brotliSize, originalSize) {
  const el = document.getElementById("winner");
  if (!el) return;

  if (gzipSize <= 0 || brotliSize <= 0 || originalSize <= 0) {
    el.className = "winner";
    el.style.display = "none";
    return;
  }

  const gzipPct = ((gzipSize / originalSize) * 100).toFixed(1);
  const brotliPct = ((brotliSize / originalSize) * 100).toFixed(1);
  const diff = formatBytes(Math.abs(gzipSize - brotliSize));

  if (brotliSize < gzipSize) {
    el.className = "winner winner-brotli";
    el.textContent = `Brotli wins -- ${brotliPct}% vs ${gzipPct}% of original (${diff} smaller)`;
    el.style.display = "block";
  } else if (gzipSize < brotliSize) {
    el.className = "winner winner-gzip";
    el.textContent = `Gzip wins -- ${gzipPct}% vs ${brotliPct}% of original (${diff} smaller)`;
    el.style.display = "block";
  } else {
    el.className = "winner winner-brotli";
    el.textContent = `Tie -- both compress to ${gzipPct}% of original`;
    el.style.display = "block";
  }
}

// ---------- Main compression pipeline ----------

let debounceTimer = null;

async function runCompressions(text) {
  hideProgress();
  const encoder = new TextEncoder();
  const data = encoder.encode(text);
  const originalSize = data.length;

  // Update original size display
  const origEl = document.getElementById("original-size");
  if (origEl) origEl.textContent = formatBytes(originalSize);

  if (originalSize === 0) {
    document.getElementById("gzip-results").innerHTML =
      '<p class="placeholder">Enter text above to see results</p>';
    document.getElementById("brotli-results").innerHTML =
      '<p class="placeholder">Enter text above to see results</p>';
    updateWinner(0, 0, 0);
    return;
  }

  // Run gzip compression
  let gzipSize = 0;
  try {
    const gzipStart = performance.now();
    const gzipResult = await gzipCompress(data);
    const gzipTime = performance.now() - gzipStart;
    gzipSize = gzipResult.length;

    renderStats("gzip-results", {
      originalSize,
      compressedSize: gzipSize,
      timeMs: gzipTime,
      availability: "All modern browsers",
    }, "gzip");
  } catch (err) {
    document.getElementById("gzip-results").innerHTML =
      '<p class="placeholder" style="color:#e94560;">Gzip compression failed</p>';
  }

  // Run brotli compression via WASM
  let brotliSize = 0;
  if (wasmMod) {
    const brotliStart = performance.now();
    const brotliResult = brotliCompress(data);
    const brotliTime = performance.now() - brotliStart;

    if (brotliResult) {
      brotliSize = brotliResult.length;
      renderStats("brotli-results", {
        originalSize,
        compressedSize: brotliSize,
        timeMs: brotliTime,
        availability: "WASM only (via Exclosured)",
      }, "brotli");
    } else {
      document.getElementById("brotli-results").innerHTML =
        '<p class="placeholder" style="color:#e94560;">Brotli compression failed</p>';
    }
  } else {
    document.getElementById("brotli-results").innerHTML =
      '<p class="placeholder">Waiting for WASM module to load...</p>';
  }

  updateWinner(gzipSize, brotliSize, originalSize);
}

// ---------- Default sample text ----------

const SAMPLE_TEXT = `The quick brown fox jumps over the lazy dog. This sentence contains every letter of the English alphabet and has been used as a typing test since at least the late 19th century.

In computer science, data compression is the process of encoding information using fewer bits than the original representation. Any particular compression is either lossy or lossless. Lossless compression reduces bits by identifying and eliminating statistical redundancy. No information is lost in lossless compression. Lossy compression reduces bits by removing unnecessary or less important information.

Brotli is a general-purpose lossless compression algorithm that compresses data using a combination of a modern variant of the LZ77 algorithm, Huffman coding, and 2nd-order context modeling. It was developed by Google and released in 2015. Brotli is primarily used for HTTP content encoding, where it achieves 20-26% better compression ratios compared to gzip/deflate.

The interesting limitation of web browsers is that while they can DECOMPRESS brotli content (the Accept-Encoding: br header is sent by all modern browsers), the JavaScript CompressionStream API does NOT support brotli compression. The API only supports "gzip" and "deflate" formats.

This means that if you want to compress data on the client side using brotli, you need to bring your own implementation. That is exactly what WebAssembly enables: you can compile a high-performance Rust implementation of brotli to WASM and run it directly in the browser.

Here is a JSON payload to demonstrate compression on structured data:
{
  "users": [
    {"id": 1, "name": "Alice Johnson", "email": "alice@example.com", "role": "admin"},
    {"id": 2, "name": "Bob Smith", "email": "bob@example.com", "role": "editor"},
    {"id": 3, "name": "Carol White", "email": "carol@example.com", "role": "viewer"},
    {"id": 4, "name": "David Brown", "email": "david@example.com", "role": "editor"},
    {"id": 5, "name": "Eva Martinez", "email": "eva@example.com", "role": "admin"}
  ],
  "metadata": {
    "total": 5,
    "page": 1,
    "per_page": 20,
    "generated_at": "2025-01-15T10:30:00Z"
  }
}

Repeated patterns compress especially well. Notice how the JSON structure above has repeated keys like "id", "name", "email", and "role" -- these are exactly the kind of patterns that compression algorithms exploit. Brotli maintains a static dictionary of common strings, which gives it an inherent advantage over gzip for web content.

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.`;

// ---------- Progress helpers ----------

function showProgress() {
  const el = document.getElementById("progress");
  if (el) el.style.display = "flex";
}

function hideProgress() {
  const el = document.getElementById("progress");
  if (el) el.style.display = "none";
}

function setStep(id, state, text) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = "progress-step " + state;
  el.textContent = text;
}

// Yield to browser so UI updates are visible
function yieldUI() {
  return new Promise((r) => setTimeout(r, 0));
}

// ---------- Run compression on raw bytes (for file input) ----------

async function runCompressionsBytes(data) {
  const originalSize = data.length;

  const origEl = document.getElementById("original-size");
  if (origEl) origEl.textContent = formatBytes(originalSize);

  if (originalSize === 0) {
    document.getElementById("gzip-results").innerHTML =
      '<p class="placeholder">Select a file to see results</p>';
    document.getElementById("brotli-results").innerHTML =
      '<p class="placeholder">Select a file to see results</p>';
    updateWinner(0, 0, 0);
    return;
  }

  showProgress();
  setStep("step-read", "done", "Read: " + formatBytes(originalSize));

  // Gzip
  let gzipSize = 0;
  setStep("step-gzip", "active", "Gzip: compressing...");
  await yieldUI();

  try {
    const gzipStart = performance.now();
    const gzipResult = await gzipCompress(data);
    const gzipTime = performance.now() - gzipStart;
    gzipSize = gzipResult.length;
    setStep("step-gzip", "done", "Gzip: " + formatBytes(gzipSize) + " in " + Math.round(gzipTime) + "ms");
    renderStats("gzip-results", {
      originalSize, compressedSize: gzipSize, timeMs: gzipTime,
      availability: "All modern browsers",
    }, "gzip");
  } catch (err) {
    setStep("step-gzip", "error", "Gzip: failed");
    document.getElementById("gzip-results").innerHTML =
      '<p class="placeholder" style="color:#e94560;">Gzip compression failed</p>';
  }

  // Brotli
  let brotliSize = 0;
  if (!wasmMod) {
    setStep("step-brotli", "error", "Brotli: WASM not loaded");
    document.getElementById("brotli-results").innerHTML =
      '<p class="placeholder">WASM module not available</p>';
  } else {
    setStep("step-brotli", "active", "Brotli: compressing...");
    await yieldUI();

    const brotliStart = performance.now();
    const brotliResult = brotliCompress(data);
    const brotliTime = performance.now() - brotliStart;

    if (brotliResult) {
      brotliSize = brotliResult.length;
      setStep("step-brotli", "done", "Brotli: " + formatBytes(brotliSize) + " in " + Math.round(brotliTime) + "ms");
      renderStats("brotli-results", {
        originalSize, compressedSize: brotliSize, timeMs: brotliTime,
        availability: "WASM only (via Exclosured)",
      }, "brotli");
    } else {
      setStep("step-brotli", "error", "Brotli: compression failed");
      document.getElementById("brotli-results").innerHTML =
        '<p class="placeholder" style="color:#e94560;">Brotli compression failed</p>';
    }
  }

  updateWinner(gzipSize, brotliSize, originalSize);
}

// ---------- Tab switching ----------

window.switchTab = function (tab) {
  const textTab = document.getElementById("tab-text");
  const fileTab = document.getElementById("tab-file");
  const textInput = document.getElementById("input-text");
  const fileInput = document.getElementById("input-file");

  if (tab === "text") {
    textTab.classList.add("active");
    fileTab.classList.remove("active");
    textInput.style.display = "block";
    fileInput.style.display = "none";
  } else {
    fileTab.classList.add("active");
    textTab.classList.remove("active");
    fileInput.style.display = "block";
    textInput.style.display = "none";
  }
};

// ---------- Initialization ----------

document.addEventListener("DOMContentLoaded", async () => {
  const textarea = document.getElementById("text-input");
  if (!textarea) return;

  // Set default text
  textarea.value = SAMPLE_TEXT;

  // Load WASM module
  await loadWasm();

  // Run initial compression on default text
  await runCompressions(SAMPLE_TEXT);

  // Quality slider
  const qualitySlider = document.getElementById("quality-slider");
  const qualityValue = document.getElementById("quality-value");
  const qualityHint = document.getElementById("quality-hint");
  const hints = { 0: "fastest", 1: "fast", 2: "fast", 3: "fast",
    4: "balanced", 5: "balanced", 6: "balanced",
    7: "slow", 8: "slow", 9: "slower", 10: "slower", 11: "max (very slow)" };

  qualitySlider.addEventListener("input", () => {
    const q = qualitySlider.value;
    qualityValue.textContent = q;
    qualityHint.textContent = hints[q] || "";
  });

  qualitySlider.addEventListener("change", () => {
    // Re-run compression with new quality
    const textPane = document.getElementById("input-text");
    if (textPane.style.display !== "none") {
      runCompressions(textarea.value);
    }
  });

  // Listen for text input changes with debounce
  textarea.addEventListener("input", () => {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      runCompressions(textarea.value);
    }, 300);
  });

  // File input handling
  const fileInput = document.getElementById("file-input");
  const dropZone = document.getElementById("drop-zone");
  const fileInfo = document.getElementById("file-info");

  async function handleFile(file) {
    fileInfo.style.display = "block";
    fileInfo.innerHTML = `<strong>${file.name}</strong> (${formatBytes(file.size)})`;

    showProgress();
    setStep("step-read", "active", "Reading file...");
    setStep("step-gzip", "", "Gzip: waiting");
    setStep("step-brotli", "", "Brotli: waiting");
    await yieldUI();

    const bytes = new Uint8Array(await file.arrayBuffer());
    await runCompressionsBytes(bytes);
  }

  fileInput.addEventListener("change", (e) => {
    if (e.target.files[0]) handleFile(e.target.files[0]);
  });

  dropZone.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropZone.classList.add("dragover");
  });

  dropZone.addEventListener("dragleave", () => {
    dropZone.classList.remove("dragover");
  });

  dropZone.addEventListener("drop", (e) => {
    e.preventDefault();
    dropZone.classList.remove("dragover");
    if (e.dataTransfer.files[0]) handleFile(e.dataTransfer.files[0]);
  });
});

// ---------- Phoenix LiveView setup ----------

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
