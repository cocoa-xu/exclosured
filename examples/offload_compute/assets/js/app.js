import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Hook: loads the WASM module and signals readiness to the LiveView
const ExclosuredHook = {
  async mounted() {
    try {
      const url = "/wasm/offload_compute_web_csv_parser.wasm";
      const response = await fetch(url);
      const { instance } = await WebAssembly.instantiateStreaming(response, {
        env: {},
      });

      window.__exclosured_wasm = instance.exports;
      window.__exclosured_memory = instance.exports.memory;

      this.pushEvent("wasm:ready", {});
    } catch (err) {
      console.error("Failed to load WASM module", err);
    }
  },
};

// Hook: attached to the WASM parse button, runs CSV parsing in WASM on click
const WasmParseHook = {
  mounted() {
    this.el.addEventListener("click", () => {
      const wasm = window.__exclosured_wasm;
      const memory = window.__exclosured_memory;

      if (!wasm || !memory) {
        console.error("WASM module not loaded yet");
        return;
      }

      // Read CSV data from the textarea
      const textarea = document.getElementById("csv-input");
      if (!textarea) return;

      const csvText = textarea.value;
      const encoder = new TextEncoder();
      const bytes = encoder.encode(csvText);

      // Allocate enough space for input and output (JSON result)
      const bufSize = Math.max(bytes.length, 1024) * 2;
      const ptr = wasm.alloc(bufSize);

      // Write the CSV bytes into WASM memory
      const view = new Uint8Array(memory.buffer, ptr, bufSize);
      view.set(bytes);

      // Time the WASM call
      const start = performance.now();
      const resultLen = wasm.parse_csv(ptr, bytes.length);
      const elapsed = performance.now() - start;

      // Read the result back from the same pointer
      const resultBytes = new Uint8Array(memory.buffer, ptr, resultLen);
      const result = new TextDecoder().decode(resultBytes);

      // Clean up
      wasm.dealloc(ptr, bufSize);

      // Push result and timing to the LiveView
      this.pushEvent("wasm_parse_result", {
        result: result,
        time_ms: parseFloat(elapsed.toFixed(3)),
      });
    });
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ExclosuredHook, WasmParseHook },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
