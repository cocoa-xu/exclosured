/**
 * Exclosured - Phoenix LiveView hook for WASM modules
 *
 * Install: npm install exclosured
 * Usage:
 *   import { ExclosuredHook } from "exclosured";
 *   let liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { Exclosured: ExclosuredHook }
 *   });
 */

// Global message bus for inter-module communication
if (typeof window !== "undefined") {
  window.__exclosured_bus = window.__exclosured_bus || new EventTarget();
}

const WORKER_SOURCE = `
let wasmModule = null;
const encoder = new TextEncoder();

self.onmessage = async (event) => {
  const message = event.data || {};

  try {
    switch (message.type) {
      case "init":
        await init(message);
        break;
      case "state":
        applyState(message);
        break;
      case "call":
        callWasm(message);
        break;
      case "broadcast":
        onBroadcast(message);
        break;
      case "destroy":
        destroy();
        break;
    }
  } catch (error) {
    postError(message.ref, message.func || "__worker__", error);
  }
};

async function init({ name, jsUrl, wasmUrl }) {
  globalThis.__exclosured = {
    emit_event: (event, payload) => {
      try {
        self.postMessage({
          type: "emit",
          event,
          payload: JSON.parse(payload),
        });
      } catch (error) {
        postError(undefined, "__emit__", error);
      }
    },
    broadcast_event: (channel, data) => {
      self.postMessage({ type: "broadcast", channel, data });
    },
  };

  try {
    const mod = await import(jsUrl);
    const wasmExports = (await mod.default(wasmUrl)) || {};
    wasmModule = Object.assign({}, wasmExports, mod);

    if (typeof wasmModule.init === "function") {
      wasmModule.init();
    }

    self.postMessage({ type: "ready" });
  } catch (error) {
    postError(undefined, "__init__", error);
  }
}

function applyState(message) {
  if (!wasmModule || typeof wasmModule.apply_state !== "function") return;

  if (Object.prototype.hasOwnProperty.call(message, "binary")) {
    wasmModule.apply_state(new Uint8Array(message.binary));
  } else {
    wasmModule.apply_state(encoder.encode(JSON.stringify(message.state)));
  }
}

function callWasm({ func, args, ref }) {
  const wasmFn = wasmModule && wasmModule[func];
  if (!wasmFn) throw new Error(\`Function '\${func}' not exported\`);

  self.postMessage({
    type: "result",
    ref,
    func,
    result: wasmFn(...args),
  });
}

function onBroadcast({ channel, data }) {
  if (wasmModule && typeof wasmModule.on_broadcast === "function") {
    wasmModule.on_broadcast(channel, data);
  }
}

function destroy() {
  if (wasmModule && typeof wasmModule.destroyed === "function") {
    wasmModule.destroyed();
  }
  wasmModule = null;
}

function postError(ref, func, error) {
  self.postMessage({
    type: "error",
    ref,
    func,
    error: error && error.message ? error.message : String(error),
  });
}
`;

export const ExclosuredHook = {
  async mounted() {
    const name = this.el.dataset.wasmModule;

    if (!name) {
      console.error("Exclosured: data-wasm-module attribute is required");
      return;
    }

    this._name = name;
    this._subscriptions = [];
    this._worker = null;
    this._workerMode = this._workerEnabled();
    this._wasmReady = false;

    try {
      if (this._workerMode) {
        await this._mountWorker(name);
      } else {
        await this._mountMainThread(name);
      }

      // State sync: LiveView -> WASM
      this.handleEvent("wasm:state", (payload) => {
        if (payload.module && payload.module !== name) return;
        this._applyStatePayload(payload);
      });

      // Handle RPC calls from LiveView
      this.handleEvent("wasm:call", ({ module, func, args, ref }) => {
        if (module && module !== name) return;
        this._callWasm(func, args, ref);
      });

      // Set up inter-module subscriptions
      this._setupSubscriptions();

      // Apply initial sync data if present
      this._applySyncData();

      // Notify server that WASM is ready
      this.pushEvent("wasm:ready", { module: name });
    } catch (err) {
      console.error(`Exclosured: failed to load module '${name}'`, err);
      if (!err._exclosuredReported) {
        this.pushEvent("wasm:error", {
          module: name,
          func: "__init__",
          error: err.message,
        });
      }
    }
  },

  async _mountMainThread(name) {
    // Set up the global namespace for wasm-bindgen imported functions
    window.__exclosured = {
      emit_event: (event, payload) => {
        try {
          this.pushEvent("wasm:emit", {
            module: name,
            event: event,
            payload: JSON.parse(payload),
          });
        } catch (e) {
          console.error("Exclosured: invalid JSON in emit payload", e);
        }
      },

      broadcast_event: (channel, data) => {
        window.__exclosured_bus.dispatchEvent(
          new CustomEvent(channel, { detail: data })
        );
      },
    };

    const jsUrl = `/wasm/${name}/${name}.js`;
    const wasmUrl = `/wasm/${name}/${name}_bg.wasm`;
    const mod = await import(/* @vite-ignore */ jsUrl);
    const wasmExports = (await mod.default(wasmUrl)) || {};
    this.wasmBindgen = Object.assign({}, wasmExports, mod);

    if (this.wasmBindgen.init) {
      const canvas = this.el.querySelector("canvas") || this._createCanvas();
      this.wasmBindgen.init(canvas);
    }

    this._wasmReady = true;
  },

  async _mountWorker(name) {
    if (this.el.querySelector("canvas")) {
      console.warn(
        "Exclosured: worker mode does not pass DOM canvas elements to WASM init()"
      );
    }

    const jsUrl = `/wasm/${name}/${name}.js`;
    const wasmUrl = `/wasm/${name}/${name}_bg.wasm`;

    await new Promise((resolve, reject) => {
      const worker = this._createWorker(name);
      let settled = false;
      this._worker = worker;

      const rejectInit = (message) => {
        if (settled) return;
        settled = true;
        worker.terminate();
        if (this._worker === worker) this._worker = null;
        const error = new Error(message);
        error._exclosuredReported = true;
        reject(error);
      };

      worker.onmessage = (event) => {
        const message = event.data || {};

        switch (message.type) {
          case "ready":
            this._wasmReady = true;
            if (!settled) {
              settled = true;
              resolve();
            }
            break;

          case "result":
            this.pushEvent("wasm:result", {
              ref: message.ref,
              module: name,
              func: message.func,
              result: message.result,
            });
            break;

          case "emit":
            this.pushEvent("wasm:emit", {
              module: name,
              event: message.event,
              payload: message.payload,
            });
            break;

          case "broadcast":
            window.__exclosured_bus.dispatchEvent(
              new CustomEvent(message.channel, { detail: message.data })
            );
            break;

          case "error":
            this.pushEvent("wasm:error", {
              ref: message.ref,
              module: name,
              func: message.func,
              error: message.error,
            });
            if (message.func === "__init__") rejectInit(message.error);
            break;
        }
      };

      worker.onerror = (event) => {
        const message = event.message || "Worker error";
        this.pushEvent("wasm:error", {
          module: name,
          func: "__worker__",
          error: message,
        });
        rejectInit(message);
      };

      worker.postMessage({ type: "init", name, jsUrl, wasmUrl });
    });
  },

  _createWorker(name) {
    const blob = new Blob([WORKER_SOURCE], { type: "text/javascript" });
    const url = URL.createObjectURL(blob);
    const worker = new Worker(url, {
      type: "module",
      name: `exclosured:${name}`,
    });
    URL.revokeObjectURL(url);
    return worker;
  },

  _workerEnabled() {
    const value = this.el.dataset.wasmWorker;
    return value === "true" || value === "";
  },

  _applyStatePayload(payload) {
    if (!this._wasmReady) return;

    if (Object.prototype.hasOwnProperty.call(payload, "binary")) {
      const binary = new Uint8Array(payload.binary);

      if (this._workerMode) {
        this._worker.postMessage({ type: "state", binary }, [binary.buffer]);
      } else if (this.wasmBindgen && this.wasmBindgen.apply_state) {
        this.wasmBindgen.apply_state(binary);
      }
    } else {
      const state = Object.prototype.hasOwnProperty.call(payload, "state")
        ? payload.state
        : payload;

      if (this._workerMode) {
        this._worker.postMessage({ type: "state", state });
      } else if (this.wasmBindgen && this.wasmBindgen.apply_state) {
        const encoded = new TextEncoder().encode(JSON.stringify(state));
        this.wasmBindgen.apply_state(encoded);
      }
    }
  },

  _callWasm(func, args, ref) {
    if (this._workerMode) {
      this._worker.postMessage({ type: "call", func, args, ref });
      return;
    }

    try {
      const fn = this.wasmBindgen[func];
      if (!fn) throw new Error(`Function '${func}' not exported`);
      const result = fn(...args);
      this.pushEvent("wasm:result", {
        ref: ref,
        module: this._name,
        func: func,
        result: result,
      });
    } catch (e) {
      this.pushEvent("wasm:error", {
        ref: ref,
        module: this._name,
        func: func,
        error: e.message,
      });
    }
  },

  // Declarative state sync: when LiveView re-renders with new sync data
  updated() {
    this._applySyncData();
  },

  _applySyncData() {
    const syncAttr = this.el.dataset.wasmSync;
    if (!syncAttr || !this._wasmReady) return;

    if (syncAttr === this._lastSyncData) return;
    this._lastSyncData = syncAttr;

    try {
      const state = JSON.parse(syncAttr);
      this._applyStatePayload({ state });
    } catch (e) {
      console.error("Exclosured: invalid sync data", e);
    }
  },

  _setupSubscriptions() {
    const subscribeAttr = this.el.dataset.wasmSubscribe;
    if (!subscribeAttr) return;

    const channels = subscribeAttr.split(",").map((s) => s.trim());
    channels.forEach((channel) => {
      const handler = (e) => {
        if (this._workerMode && this._worker) {
          this._worker.postMessage({
            type: "broadcast",
            channel,
            data: e.detail,
          });
        } else if (this.wasmBindgen && this.wasmBindgen.on_broadcast) {
          this.wasmBindgen.on_broadcast(channel, e.detail);
        }
      };
      window.__exclosured_bus.addEventListener(channel, handler);
      this._subscriptions.push({ channel, handler });
    });
  },

  _createCanvas() {
    const canvas = document.createElement("canvas");
    canvas.width = this.el.dataset.wasmWidth || 800;
    canvas.height = this.el.dataset.wasmHeight || 600;
    this.el.appendChild(canvas);
    return canvas;
  },

  destroyed() {
    this._subscriptions.forEach(({ channel, handler }) => {
      window.__exclosured_bus.removeEventListener(channel, handler);
    });
    this._subscriptions = [];
    if (this._worker) {
      this._worker.postMessage({ type: "destroy" });
      this._worker.terminate();
      this._worker = null;
    } else if (
      this.wasmBindgen &&
      typeof this.wasmBindgen.destroyed === "function"
    ) {
      try {
        this.wasmBindgen.destroyed();
      } catch (e) {
        console.error("Exclosured: error in WASM destroyed() callback", e);
      }
    }
    this.wasmBindgen = null;
    this._wasmReady = false;
  },
};

export default ExclosuredHook;
