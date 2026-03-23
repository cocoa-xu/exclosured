import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Import the Exclosured LiveView hook
// In a real app, this would come from the exclosured npm package or a copy
// For this demo, we inline the hook logic

const ExclosuredHook = {
  async mounted() {
    const name = this.el.dataset.wasmModule;
    const mode = this.el.dataset.wasmMode || "compute";

    if (!name) return;
    this._name = name;

    try {
      const mod = await import(`/wasm/${name}/${name}.js`);
      const wasm = await mod.default(`/wasm/${name}/${name}_bg.wasm`);
      window.__exclosured_wasm = wasm;
      window.__exclosured_memory = wasm.memory;

      this.wasm = wasm;
      this.memory = wasm.memory;

      this.handleEvent("wasm:call", ({ func, args, ref }) => {
        try {
          const result = this._callWasm(func, args);
          this.pushEvent("wasm:result", {
            ref,
            module: name,
            func,
            result,
          });
        } catch (e) {
          this.pushEvent("wasm:error", {
            ref,
            module: name,
            func,
            error: e.message,
          });
        }
      });

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

  _callWasm(func, args) {
    const fn_ = this.wasm[func];
    if (!fn_) throw new Error(`Function '${func}' not exported`);

    const wasmArgs = args.flatMap((arg) => {
      if (typeof arg === "string") {
        const { ptr, len } = this._writeString(arg);
        return [ptr, len];
      }
      return [arg];
    });

    return fn_(...wasmArgs);
  },

  _readString(ptr, len) {
    return new TextDecoder().decode(
      new Uint8Array(this.memory.buffer, ptr, len)
    );
  },

  _writeString(str) {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(str);
    const ptr = this.wasm.alloc(bytes.length);
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  },

  destroyed() {
    this.wasm = null;
    this.memory = null;
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
