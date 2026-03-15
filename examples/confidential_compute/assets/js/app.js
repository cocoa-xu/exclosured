import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Hook: Load WASM module and store references globally
const ExclosuredHook = {
  async mounted() {
    try {
      const url = "/wasm/confidential_compute_web_validators.wasm";
      const response = fetch(url);
      const { instance } = await WebAssembly.instantiateStreaming(response, {
        env: {},
      });

      window.__exclosured_wasm = instance;
      window.__exclosured_memory = instance.exports.memory;

      this.pushEvent("wasm:ready", {});
    } catch (err) {
      console.error("Failed to load WASM module:", err);
    }
  },
};

// Hook: Password strength checking via WASM
const WasmPasswordHook = {
  mounted() {
    this.el.addEventListener("input", () => {
      const wasm = window.__exclosured_wasm;
      const memory = window.__exclosured_memory;
      if (!wasm || !memory) return;

      const value = this.el.value;
      if (value.length === 0) return;

      try {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(value);
        const inputLen = encoded.length;
        const bufSize = Math.max(inputLen, 256);

        const ptr = wasm.exports.alloc(bufSize);
        const view = new Uint8Array(memory.buffer, ptr, bufSize);
        view.set(encoded);

        const resultLen = wasm.exports.check_password(ptr, inputLen);

        const resultBytes = new Uint8Array(memory.buffer, ptr, resultLen);
        const resultStr = new TextDecoder().decode(resultBytes);
        const result = JSON.parse(resultStr);

        wasm.exports.dealloc(ptr, bufSize);

        this.pushEvent("pw_checked", {
          score: result.score,
          label: result.label,
          length: result.length,
        });
      } catch (err) {
        console.error("Password check error:", err);
      }
    });
  },
};

// Hook: SSN masking via WASM
const WasmSsnHook = {
  mounted() {
    this.el.addEventListener("input", () => {
      const wasm = window.__exclosured_wasm;
      const memory = window.__exclosured_memory;
      if (!wasm || !memory) return;

      const value = this.el.value;
      if (value.length === 0) return;

      try {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(value);
        const inputLen = encoded.length;
        const bufSize = Math.max(inputLen, 256);

        const ptr = wasm.exports.alloc(bufSize);
        const view = new Uint8Array(memory.buffer, ptr, bufSize);
        view.set(encoded);

        const resultLen = wasm.exports.mask_ssn(ptr, inputLen);

        const resultBytes = new Uint8Array(memory.buffer, ptr, resultLen);
        const resultStr = new TextDecoder().decode(resultBytes);
        const result = JSON.parse(resultStr);

        wasm.exports.dealloc(ptr, bufSize);

        this.pushEvent("ssn_masked", {
          valid: result.valid,
          masked: result.masked,
        });
      } catch (err) {
        console.error("SSN mask error:", err);
      }
    });
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: {
    ExclosuredHook: ExclosuredHook,
    WasmPasswordHook: WasmPasswordHook,
    WasmSsnHook: WasmSsnHook,
  },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
