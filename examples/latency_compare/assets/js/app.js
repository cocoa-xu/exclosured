import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// === ExclosuredHook =========================================================
// Standard WASM loader for compute-mode modules. Loads the .wasm file,
// instantiates it, and stores exports + memory on window globals.

const ExclosuredHook = {
  async mounted() {
    try {
      const name = "image_filter";
      const mod = await import(`/wasm/${name}/${name}.js`);
      const wasm = await mod.default(`/wasm/${name}/${name}_bg.wasm`);
      window.__exclosured_wasm = wasm;
      window.__exclosured_memory = wasm.memory;
      this.pushEvent("wasm:ready", {});
    } catch (err) {
      console.error("Failed to load WASM module 'image_filter'", err);
    }
  },
};

// === CompareHook ============================================================
// Attached to the canvas container. Handles test pattern generation,
// WASM image loading, and the four filter modes:
// - Pure JS: JavaScript pixel loop (local)
// - WASM: Rust compiled to WASM (local)
// - Server (Vix): libvips on server (round-trip)
// - Server (evision): OpenCV on server (round-trip)

const CompareHook = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.W = this.canvas.width;
    this.H = this.canvas.height;
    this.wasm = null;
    this.pendingTimestamp = null;
    this.originalImageData = null;

    // Register server event handler before any async work
    this.handleEvent("server:filter_result", (payload) => {
      this._onServerResult(payload);
    });

    this._loadWasmAndInit();
    this._setupSliderListeners();
  },

  async _loadWasmAndInit() {
    await this._ensureWasm();
    this.pushEvent("wasm:ready", {});

    // Generate and render the test pattern
    this._generateTestPattern();

    // Store original pixels for JS filter mode
    this.originalImageData = this.ctx.getImageData(0, 0, this.W, this.H);

    // Load the test pattern pixels into WASM
    this._pushPixelsToWasm();

    // Upload pixels to server for server-side filter modes
    this._uploadToServer();

    // Initial render (identity filter)
    this._applyWasmFilter(0, 0);
  },

  async _ensureWasm() {
    // If already loaded, use it
    if (window.__exclosured_wasm) {
      this.wasm = window.__exclosured_wasm;
      return;
    }

    // Otherwise load it ourselves
    try {
      const name = "image_filter";
      const mod = await import(`/wasm/${name}/${name}.js`);
      const wasm = await mod.default(`/wasm/${name}/${name}_bg.wasm`);
      window.__exclosured_wasm = wasm;
      window.__exclosured_memory = wasm.memory;
      this.wasm = wasm;
    } catch (err) {
      console.error("Failed to load WASM module", err);
    }
  },

  // Generate a visually appealing 256x256 test pattern:
  // concentric rings with a rainbow gradient overlay and some geometric shapes.
  _generateTestPattern() {
    const w = this.W;
    const h = this.H;
    const imgData = this.ctx.createImageData(w, h);
    const data = imgData.data;
    const cx = w / 2;
    const cy = h / 2;

    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const idx = (y * w + x) * 4;

        // Distance from center (normalized 0..1)
        const dx = (x - cx) / cx;
        const dy = (y - cy) / cy;
        const dist = Math.sqrt(dx * dx + dy * dy);

        // Angle for rainbow hue (0..1)
        const angle = (Math.atan2(dy, dx) / Math.PI + 1.0) / 2.0;

        // Concentric rings
        const ring = Math.sin(dist * 12.0 * Math.PI) * 0.5 + 0.5;

        // Rainbow color based on angle
        const hue = angle * 360;
        const rgb = hslToRgb(hue, 0.8, 0.45 + ring * 0.15);

        // Diamond pattern overlay
        const diamond = Math.abs(dx) + Math.abs(dy);
        const diamondEdge = Math.abs(Math.sin(diamond * 8.0 * Math.PI));

        // Blend: base rainbow with ring modulation + diamond highlight
        const highlight = diamondEdge > 0.95 ? 0.3 : 0.0;

        data[idx] = Math.min(255, rgb[0] + highlight * 255);
        data[idx + 1] = Math.min(255, rgb[1] + highlight * 255);
        data[idx + 2] = Math.min(255, rgb[2] + highlight * 255);
        data[idx + 3] = 255;
      }
    }

    this.ctx.putImageData(imgData, 0, 0);
  },

  _pushPixelsToWasm() {
    if (!this.wasm) return;
    const imgData = this.ctx.getImageData(0, 0, this.W, this.H);
    const src = imgData.data;
    const ptr = this.wasm.alloc(src.length);
    new Uint8Array(this.wasm.memory.buffer, ptr, src.length).set(src);
    this.wasm.load_image(ptr, src.length, this.W, this.H);
    this.wasm.dealloc(ptr, src.length);
  },

  _uploadToServer() {
    const bytes = this.originalImageData.data;
    // Convert to base64 in chunks to avoid call stack overflow
    const chunks = [];
    for (let i = 0; i < bytes.length; i += 8192) {
      chunks.push(
        String.fromCharCode.apply(null, bytes.subarray(i, i + 8192))
      );
    }
    const base64 = btoa(chunks.join(""));
    this.pushEvent("upload_image", {
      pixels: base64,
      width: this.W,
      height: this.H,
    });
  },

  _applyJsFilter(brightness, contrast) {
    // Copy original image data (never mutate the original)
    const imgData = new ImageData(
      new Uint8ClampedArray(this.originalImageData.data),
      this.W,
      this.H
    );
    const data = imgData.data;

    // Same formula as the Rust WASM filter for fair comparison
    const cFactor = (contrast + 100) / 100;
    const bOffset = brightness / 100;

    for (let i = 0; i < data.length; i += 4) {
      for (let ch = 0; ch < 3; ch++) {
        const val = data[i + ch] / 255;
        const contrasted = (val - 0.5) * cFactor + 0.5;
        const result = contrasted + bOffset;
        data[i + ch] = Math.max(0, Math.min(255, Math.round(result * 255)));
      }
      // Alpha unchanged
    }

    this.ctx.putImageData(imgData, 0, 0);
  },

  _applyWasmFilter(brightness, contrast) {
    if (!this.wasm) return;
    this.wasm.apply_filter(brightness, contrast);
    const ptr = this.wasm.canvas_ptr();
    const len = this.wasm.canvas_len();
    const pixels = new Uint8ClampedArray(
      this.wasm.memory.buffer,
      ptr,
      len
    );
    const imgData = new ImageData(pixels, this.W, this.H);
    this.ctx.putImageData(imgData, 0, 0);
  },

  _setupSliderListeners() {
    // Listen on the actual slider inputs for real-time "input" events.
    // Local modes: apply filter directly (zero network).
    // Server modes: record timestamp and let phx-change handle the round-trip.
    const brightnessSlider = document.getElementById("brightness-slider");
    const contrastSlider = document.getElementById("contrast-slider");

    const onInput = () => {
      const mode = this.el.dataset.mode;
      const b = parseInt(brightnessSlider.value, 10);
      const c = parseInt(contrastSlider.value, 10);

      if (mode === "js") {
        const start = performance.now();
        this._applyJsFilter(b, c);
        const elapsed = parseFloat((performance.now() - start).toFixed(1));
        this.pushEvent("report_latency", { ms: elapsed });
      } else if (mode === "wasm") {
        const start = performance.now();
        this._applyWasmFilter(b, c);
        const elapsed = parseFloat((performance.now() - start).toFixed(1));
        this.pushEvent("report_latency", { ms: elapsed });
      } else {
        // Server modes (vix, evision): record the send timestamp.
        // The phx-change on the form will fire and send to server.
        // Server applies filter and pushes back filtered pixels.
        this.pendingTimestamp = performance.now();
      }
    };

    if (brightnessSlider) {
      brightnessSlider.addEventListener("input", onInput);
    }
    if (contrastSlider) {
      contrastSlider.addEventListener("input", onInput);
    }
  },

  _onServerResult(payload) {
    // Server sent back filtered pixels as base64-encoded RGBA
    const binary = atob(payload.pixels);
    const bytes = new Uint8ClampedArray(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    const imgData = new ImageData(bytes, this.W, this.H);
    this.ctx.putImageData(imgData, 0, 0);

    if (this.pendingTimestamp) {
      const roundTrip = Math.round(performance.now() - this.pendingTimestamp);
      this.pendingTimestamp = null;
      const serverCompute = parseFloat(
        (payload.server_time_us / 1000).toFixed(2)
      );
      this.pushEvent("report_latency", {
        ms: roundTrip,
        server_compute_ms: serverCompute,
      });
    }
  },

  destroyed() {
    this.wasm = null;
  },
};

// Convert HSL (h: 0-360, s: 0-1, l: 0-1) to RGB array [r, g, b] (0-255)
function hslToRgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  let r, g, b;

  if (h < 60) {
    r = c; g = x; b = 0;
  } else if (h < 120) {
    r = x; g = c; b = 0;
  } else if (h < 180) {
    r = 0; g = c; b = x;
  } else if (h < 240) {
    r = 0; g = x; b = c;
  } else if (h < 300) {
    r = x; g = 0; b = c;
  } else {
    r = c; g = 0; b = x;
  }

  return [
    Math.round((r + m) * 255),
    Math.round((g + m) * 255),
    Math.round((b + m) * 255),
  ];
}

// === LiveSocket setup ========================================================

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { Exclosured: ExclosuredHook, Compare: CompareHook },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
