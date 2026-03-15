import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const ExclosuredHook = {
  async mounted() {
    const name = this.el.dataset.wasmModule;
    const mode = this.el.dataset.wasmMode || "compute";

    if (!name) return;
    this._name = name;

    try {
      if (mode === "interactive") {
        await this._mountInteractive(name);
      }

      this.pushEvent("wasm:ready", { module: name });
    } catch (err) {
      console.error(`Failed to load WASM module '${name}'`, err);
      this.pushEvent("wasm:error", {
        module: name,
        func: "__init__",
        error: err.message,
      });
    }
  },

  async _mountInteractive(name) {
    const canvas = this.el.querySelector("canvas");
    if (!canvas) {
      throw new Error("No canvas element found for interactive mode");
    }

    // Import wasm-bindgen JS glue
    const wasm = await import(`/wasm/${name}/${name}.js`);
    await wasm.default(`/wasm/${name}/${name}_bg.wasm`);
    this.wasmBindgen = wasm;

    if (wasm.init) {
      wasm.init(canvas);
    }

    // State sync: LiveView -> WASM
    this.handleEvent("wasm:state", (state) => {
      if (wasm.apply_state) {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(JSON.stringify(state));
        wasm.apply_state(encoded);
      }
    });
  },

  destroyed() {
    this.wasmBindgen = null;
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { Exclosured: ExclosuredHook },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
