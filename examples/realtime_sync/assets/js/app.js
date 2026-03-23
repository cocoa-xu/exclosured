import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

function hexToRgba(hex) {
  return {
    r: parseInt(hex.slice(1, 3), 16),
    g: parseInt(hex.slice(3, 5), 16),
    b: parseInt(hex.slice(5, 7), 16),
    a: 255,
  };
}

const CollabEditor = {
  async mounted() {
    this.canvas = document.getElementById("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.dropZone = document.getElementById("drop-zone");
    this.fileInput = document.getElementById("file-input");
    this.W = this.canvas.width;
    this.H = this.canvas.height;

    this.hasImage = false;
    this.wasm = null;
    this.tool = "pen";
    this.penColor = "#ff6b6b";
    this.penSize = 4;
    this.drawing = false;
    this.lastX = 0;
    this.lastY = 0;

    // Register LiveView event handlers (synchronous, before any async work)
    this.handleEvent("load_snapshot", (payload) => this._onLoadSnapshot(payload));
    this.handleEvent("remote_draw", (op) => this._onRemoteDraw(op));
    this.handleEvent("remote_filter", ({ name }) => this._onRemoteFilter(name));

    this._setupFileInput();
    this._setupDrawing();
    this._setupToolbar();

    await this._loadWasm();
  },

  // --- WASM ---

  async _loadWasm() {
    try {
      const name = "sync_client";
      const mod = await import(`/wasm/${name}/${name}.js`);
      const wasm = await mod.default(`/wasm/${name}/${name}_bg.wasm`);
      window.__exclosured_wasm = wasm;
      window.__exclosured_memory = wasm.memory;
      this.wasm = wasm;
      this.wasm.init_canvas(this.W, this.H);
      // Tell server WASM is ready; server will send room state if any
      this.pushEvent("wasm:ready", {});
    } catch (e) {
      console.error("WASM load failed", e);
    }
  },

  _renderFromWasm() {
    if (!this.wasm) return;
    const ptr = this.wasm.canvas_ptr();
    const len = this.wasm.canvas_len();
    const pixels = new Uint8ClampedArray(this.wasm.memory.buffer, ptr, len);
    const imgData = new ImageData(pixels, this.W, this.H);
    this.ctx.putImageData(imgData, 0, 0);
  },

  _pushToWasm() {
    if (!this.wasm) return;
    const imgData = this.ctx.getImageData(0, 0, this.W, this.H);
    const src = imgData.data;
    const ptr = this.wasm.alloc(src.length);
    new Uint8Array(this.wasm.memory.buffer, ptr, src.length).set(src);
    this.wasm.load_pixels(ptr, src.length, this.W, this.H);
    this.wasm.dealloc(ptr, src.length);
  },

  /** Read WASM buffer, compress with deflate, return base64 string. */
  _snapshotToBase64() {
    if (!this.wasm) return null;
    const ptr = this.wasm.canvas_ptr();
    const len = this.wasm.canvas_len();
    const raw = new Uint8Array(this.wasm.memory.buffer, ptr, len);
    // Compress with DecompressionStream/CompressionStream if available,
    // otherwise send raw. For simplicity, just base64 the raw bytes.
    return this._uint8ToBase64(raw);
  },

  _uint8ToBase64(bytes) {
    let binary = "";
    const chunkSize = 32768;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode.apply(
        null,
        bytes.subarray(i, i + chunkSize)
      );
    }
    return btoa(binary);
  },

  _base64ToUint8(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  },

  // --- Server events ---

  _onLoadSnapshot(payload) {
    if (!this.wasm) return;
    const rgba = this._base64ToUint8(payload.data);
    const ptr = this.wasm.alloc(rgba.length);
    new Uint8Array(this.wasm.memory.buffer, ptr, rgba.length).set(rgba);
    this.wasm.load_pixels(ptr, rgba.length, this.W, this.H);
    this.wasm.dealloc(ptr, rgba.length);
    this._renderFromWasm();
    this.hasImage = true;
    this.dropZone.style.display = "none";
  },

  _onRemoteDraw(op) {
    if (!this.wasm || !this.hasImage) return;
    this.wasm.draw_line(
      op.x0, op.y0, op.x1, op.y1,
      op.r, op.g, op.b, op.a,
      op.size, op.eraser
    );
    this._renderFromWasm();
  },

  _onRemoteFilter(name) {
    this._applyFilterLocal(name);
  },

  // --- File handling ---

  _setupFileInput() {
    this.fileInput.addEventListener("change", (e) => {
      if (e.target.files[0]) this._loadImageFile(e.target.files[0]);
    });

    this.dropZone.addEventListener("dragover", (e) => {
      e.preventDefault();
      this.dropZone.classList.add("dragover");
    });
    this.dropZone.addEventListener("dragleave", () => {
      this.dropZone.classList.remove("dragover");
    });
    this.dropZone.addEventListener("drop", (e) => {
      e.preventDefault();
      this.dropZone.classList.remove("dragover");
      if (e.dataTransfer.files[0]) this._loadImageFile(e.dataTransfer.files[0]);
    });
  },

  _loadImageFile(file) {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(this.W / img.width, this.H / img.height, 1);
      const w = img.width * scale;
      const h = img.height * scale;
      const x = (this.W - w) / 2;
      const y = (this.H - h) / 2;

      this.ctx.fillStyle = "#1a1a2e";
      this.ctx.fillRect(0, 0, this.W, this.H);
      this.ctx.drawImage(img, x, y, w, h);
      URL.revokeObjectURL(url);

      this._pushToWasm();
      this.dropZone.style.display = "none";
      this.hasImage = true;

      // Send to server so other users (current and future) get it
      const b64 = this._snapshotToBase64();
      if (b64) {
        this.pushEvent("upload_image", { data: b64 });
      }
    };
    img.src = url;
  },

  // --- Drawing ---

  _setupDrawing() {
    this.canvas.addEventListener("mousedown", (e) => {
      if (!this.hasImage) return;
      this.drawing = true;
      const rect = this.canvas.getBoundingClientRect();
      this.lastX = e.clientX - rect.left;
      this.lastY = e.clientY - rect.top;
    });

    this.canvas.addEventListener("mousemove", (e) => {
      if (!this.drawing || !this.wasm) return;
      const rect = this.canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;

      const isEraser = this.tool === "eraser";
      const rgba = hexToRgba(this.penColor);

      // Apply locally in WASM
      this.wasm.draw_line(
        this.lastX, this.lastY, x, y,
        rgba.r, rgba.g, rgba.b, rgba.a,
        this.penSize, isEraser ? 1 : 0
      );
      this._renderFromWasm();

      // Broadcast to other users via LiveView
      this.pushEvent("draw", {
        x0: this.lastX, y0: this.lastY,
        x1: x, y1: y,
        r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a,
        size: this.penSize,
        eraser: isEraser ? 1 : 0,
      });

      this.lastX = x;
      this.lastY = y;
    });

    this.canvas.addEventListener("mouseup", () => (this.drawing = false));
    this.canvas.addEventListener("mouseleave", () => (this.drawing = false));
  },

  // --- Filters ---

  _applyFilter(name) {
    this._applyFilterLocal(name);

    // Broadcast filter command to other users
    this.pushEvent("apply_filter", { name });

    // Send updated snapshot so future joiners get the filtered version
    const b64 = this._snapshotToBase64();
    if (b64) {
      this.pushEvent("bake_snapshot", { data: b64 });
    }
  },

  _applyFilterLocal(name) {
    if (!this.wasm || !this.hasImage) return;
    switch (name) {
      case "grayscale":
        this.wasm.filter_grayscale();
        break;
      case "invert":
        this.wasm.filter_invert();
        break;
      case "sepia":
        this.wasm.filter_sepia();
        break;
      case "brightness":
        this.wasm.filter_brightness(30);
        break;
      case "blur":
        this.wasm.filter_blur(2);
        break;
    }
    this._renderFromWasm();
  },

  // --- Toolbar ---

  _setupToolbar() {
    document.querySelectorAll(".tool").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".tool").forEach((b) =>
          b.classList.remove("active")
        );
        btn.classList.add("active");
        this.tool = btn.dataset.tool;
      });
    });

    document.getElementById("pen-color").addEventListener("input", (e) => {
      this.penColor = e.target.value;
    });
    document.getElementById("pen-size").addEventListener("input", (e) => {
      this.penSize = parseInt(e.target.value);
    });

    document.querySelectorAll(".filter-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        this._applyFilter(btn.dataset.filter);
      });
    });
  },

  destroyed() {
    this.wasm = null;
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { CollabEditor },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
