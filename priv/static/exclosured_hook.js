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

const RUNTIME_KEY = "__exclosured_runtime";
const DISPATCHER_MARKER = "__exclosured_dispatcher";

function getExclosuredBus() {
  if (typeof window === "undefined") return null;
  window.__exclosured_bus = window.__exclosured_bus || new EventTarget();
  return window.__exclosured_bus;
}

function getExclosuredRuntime() {
  if (typeof window === "undefined") return null;

  window[RUNTIME_KEY] = window[RUNTIME_KEY] || {
    contexts: new Map(),
    contextStack: [],
    nextId: 1,
    lastContextId: null,
  };

  if (
    !window.__exclosured ||
    window.__exclosured[DISPATCHER_MARKER] !== true
  ) {
    window.__exclosured = createHostDispatcher(window[RUNTIME_KEY]);
  }

  getExclosuredBus();
  return window[RUNTIME_KEY];
}

function createHostDispatcher(runtime) {
  return {
    [DISPATCHER_MARKER]: true,

    emit_event(event, payload) {
      const context = activeHostContext(runtime);

      if (!context) {
        console.error("Exclosured: no active host context for emit_event");
        return;
      }

      context.emitEvent(event, payload);
    },

    broadcast_event(channel, data) {
      const context = activeHostContext(runtime);

      if (context) {
        context.broadcastEvent(channel, data);
      } else {
        dispatchBroadcast(channel, data);
      }
    },
  };
}

function activeHostContext(runtime) {
  const id =
    runtime.contextStack[runtime.contextStack.length - 1] ||
    runtime.lastContextId;

  return id ? runtime.contexts.get(id) : null;
}

function withHostContext(context, callback) {
  const runtime = getExclosuredRuntime();
  if (!runtime || !context) return callback();

  runtime.contextStack.push(context.id);
  runtime.lastContextId = context.id;

  let result;

  try {
    result = callback();
  } catch (error) {
    removeHostContextFrame(runtime, context.id);
    throw error;
  }

  if (result && typeof result.then === "function") {
    return Promise.resolve(result).finally(() => {
      removeHostContextFrame(runtime, context.id);
    });
  }

  removeHostContextFrame(runtime, context.id);
  return result;
}

function removeHostContextFrame(runtime, id) {
  const index = runtime.contextStack.lastIndexOf(id);
  if (index !== -1) runtime.contextStack.splice(index, 1);
}

function dispatchBroadcast(channel, data) {
  const bus = getExclosuredBus();
  if (!bus) return;
  bus.dispatchEvent(new CustomEvent(channel, { detail: data }));
}

function bytesFromPayload(value, encoding) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (Array.isArray(value)) return new Uint8Array(value);
  if (encoding === "base64" && typeof value === "string") {
    return base64ToBytes(value);
  }
  return new Uint8Array(value);
}

function base64ToBytes(value) {
  const binary =
    typeof atob === "function"
      ? atob(value)
      : Buffer.from(value, "base64").toString("binary");

  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

getExclosuredRuntime();

const WORKER_SOURCE = `
let wasmModule = null;
const encoder = new TextEncoder();
const canceledCalls = new Set();

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
        await callWasm(message);
        break;
      case "cancel":
        cancelCall(message);
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
    wasmModule.apply_state(
      bytesFromPayload(
        message.binary,
        message.binaryEncoding || message.binary_encoding
      )
    );
  } else {
    wasmModule.apply_state(encoder.encode(JSON.stringify(message.state)));
  }
}

function bytesFromPayload(value, encoding) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (Array.isArray(value)) return new Uint8Array(value);
  if (encoding === "base64" && typeof value === "string") {
    return base64ToBytes(value);
  }
  return new Uint8Array(value);
}

function base64ToBytes(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function callWasm({ func, args, ref }) {
  const wasmFn = wasmModule && wasmModule[func];
  if (!wasmFn) throw new Error(\`Function '\${func}' not exported\`);
  const result = await wasmFn(...args);

  if (consumeCanceledCall(ref)) return;

  self.postMessage({
    type: "result",
    ref,
    func,
    result,
  });
}

function cancelCall({ ref }) {
  if (ref == null) return;
  canceledCalls.add(ref);

  if (wasmModule && typeof wasmModule.cancel_call === "function") {
    try {
      wasmModule.cancel_call(ref);
    } catch (error) {
      console.error("Exclosured: cancel_call failed", error);
    }
  }
}

function consumeCanceledCall(ref) {
  if (ref == null || !canceledCalls.has(ref)) return false;
  canceledCalls.delete(ref);
  return true;
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
  if (consumeCanceledCall(ref)) return;

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
    this._canceledCalls = new Set();
    this._hostContext = this._workerMode
      ? null
      : this._registerHostContext(name);

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

      this.handleEvent("wasm:cancel", ({ module, ref }) => {
        if (module && module !== name) return;
        this._cancelWasmCall(ref);
      });

      // Set up inter-module subscriptions
      this._setupSubscriptions();

      // Apply initial sync data if present
      this._applySyncData();

      // Notify server that WASM is ready
      this.pushEvent("wasm:ready", { module: name });
    } catch (err) {
      this._unregisterHostContext();
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
    const jsUrl = `/wasm/${name}/${name}.js`;
    const wasmUrl = `/wasm/${name}/${name}_bg.wasm`;
    const mod = await import(/* @vite-ignore */ jsUrl);
    const wasmExports =
      (await this._withHostContext(() => mod.default(wasmUrl))) || {};
    this.wasmBindgen = Object.assign({}, wasmExports, mod);

    if (this.wasmBindgen.init) {
      const canvas = this.el.querySelector("canvas") || this._createCanvas();
      await this._withHostContext(() => this.wasmBindgen.init(canvas));
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
            dispatchBroadcast(message.channel, message.data);
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
      const binary = bytesFromPayload(
        payload.binary,
        payload.binaryEncoding || payload.binary_encoding
      );

      if (this._workerMode) {
        this._worker.postMessage({ type: "state", binary }, [binary.buffer]);
      } else if (this.wasmBindgen && this.wasmBindgen.apply_state) {
        this._withHostContext(() => this.wasmBindgen.apply_state(binary));
      }
    } else {
      const state = Object.prototype.hasOwnProperty.call(payload, "state")
        ? payload.state
        : payload;

      if (this._workerMode) {
        this._worker.postMessage({ type: "state", state });
      } else if (this.wasmBindgen && this.wasmBindgen.apply_state) {
        const encoded = new TextEncoder().encode(JSON.stringify(state));
        this._withHostContext(() => this.wasmBindgen.apply_state(encoded));
      }
    }
  },

  async _callWasm(func, args, ref) {
    if (this._workerMode) {
      this._worker.postMessage({ type: "call", func, args, ref });
      return;
    }

    try {
      const fn = this.wasmBindgen[func];
      if (!fn) throw new Error(`Function '${func}' not exported`);
      const result = await this._withHostContext(() => fn(...args));
      if (!this._wasmReady || this._consumeCanceledCall(ref)) return;
      this.pushEvent("wasm:result", {
        ref: ref,
        module: this._name,
        func: func,
        result: result,
      });
    } catch (e) {
      if (!this._wasmReady || this._consumeCanceledCall(ref)) return;
      this.pushEvent("wasm:error", {
        ref: ref,
        module: this._name,
        func: func,
        error: e.message,
      });
    }
  },

  _cancelWasmCall(ref) {
    if (ref == null) return;
    this._canceledCalls.add(ref);

    if (this._workerMode) {
      this._worker.postMessage({ type: "cancel", ref });
    } else if (
      this.wasmBindgen &&
      typeof this.wasmBindgen.cancel_call === "function"
    ) {
      try {
        this._withHostContext(() => this.wasmBindgen.cancel_call(ref));
      } catch (e) {
        console.error("Exclosured: cancel_call failed", e);
      }
    }
  },

  _consumeCanceledCall(ref) {
    if (ref == null || !this._canceledCalls.has(ref)) return false;
    this._canceledCalls.delete(ref);
    return true;
  },

  _registerHostContext(name) {
    const runtime = getExclosuredRuntime();
    if (!runtime) return null;

    const id = `${name}:${runtime.nextId++}`;
    const context = {
      id,
      name,
      emitEvent: (event, payload) => this._emitFromGuest(event, payload),
      broadcastEvent: (channel, data) => dispatchBroadcast(channel, data),
    };

    runtime.contexts.set(id, context);
    runtime.lastContextId = id;
    return context;
  },

  _unregisterHostContext() {
    const runtime = getExclosuredRuntime();
    const context = this._hostContext;
    if (!runtime || !context) return;

    runtime.contexts.delete(context.id);
    runtime.contextStack = runtime.contextStack.filter(
      (id) => id !== context.id
    );

    if (runtime.lastContextId === context.id) {
      runtime.lastContextId = Array.from(runtime.contexts.keys()).pop() || null;
    }

    this._hostContext = null;
  },

  _withHostContext(callback) {
    return withHostContext(this._hostContext, callback);
  },

  _emitFromGuest(event, payload) {
    try {
      this.pushEvent("wasm:emit", {
        module: this._name,
        event: event,
        payload: JSON.parse(payload),
      });
    } catch (e) {
      console.error("Exclosured: invalid JSON in emit payload", e);
    }
  },

  // Declarative state sync: when LiveView re-renders with new sync data
  updated() {
    this._applySyncData();
  },

  _applySyncData() {
    const syncAttr = this.el.dataset.wasmSync;
    if (!syncAttr || !this._wasmReady) return;

    const encoding = this.el.dataset.wasmSyncEncoding || "json";
    const syncKey = `${encoding}:${syncAttr}`;

    if (syncKey === this._lastSyncData) return;
    this._lastSyncData = syncKey;

    if (encoding === "binary") {
      this._applyStatePayload({
        binary: syncAttr,
        binaryEncoding: "base64",
      });
      return;
    }

    if (encoding !== "json") {
      console.error(`Exclosured: unsupported sync encoding '${encoding}'`);
      return;
    }

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
          this._withHostContext(() =>
            this.wasmBindgen.on_broadcast(channel, e.detail)
          );
        }
      };
      getExclosuredBus().addEventListener(channel, handler);
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
      getExclosuredBus().removeEventListener(channel, handler);
    });
    this._subscriptions = [];

    try {
      if (this._worker) {
        this._worker.postMessage({ type: "destroy" });
        this._worker.terminate();
        this._worker = null;
      } else if (
        this.wasmBindgen &&
        typeof this.wasmBindgen.destroyed === "function"
      ) {
        try {
          this._withHostContext(() => this.wasmBindgen.destroyed());
        } catch (e) {
          console.error("Exclosured: error in WASM destroyed() callback", e);
        }
      }
    } finally {
      this._unregisterHostContext();
    }

    this.wasmBindgen = null;
    this._wasmReady = false;
  },
};

export default ExclosuredHook;
