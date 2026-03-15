/**
 * Exclosured LiveView Hook
 *
 * Integrates WebAssembly modules with Phoenix LiveView for bidirectional
 * communication between server-side Elixir and client-side WASM.
 */

// Global message bus for inter-module communication
window.__exclosured_bus = window.__exclosured_bus || new EventTarget();

const ExclosuredHook = {
  async mounted() {
    const name = this.el.dataset.wasmModule;
    const mode = this.el.dataset.wasmMode || "compute";

    if (!name) {
      console.error("Exclosured: data-wasm-module attribute is required");
      return;
    }

    this._name = name;
    this._mode = mode;
    this._subscriptions = [];

    try {
      if (mode === "interactive") {
        await this._mountInteractive(name);
      } else {
        await this._mountCompute(name);
      }

      // Set up inter-module subscriptions
      this._setupSubscriptions();

      // Notify server that WASM is ready
      this.pushEvent("wasm:ready", { module: name });
    } catch (err) {
      console.error(`Exclosured: failed to load module '${name}'`, err);
      this.pushEvent("wasm:error", {
        module: name,
        func: "__init__",
        error: err.message,
      });
    }
  },

  async _mountCompute(name) {
    const url = `/wasm/${name}.wasm`;
    const response = fetch(url);

    const { instance } = await WebAssembly.instantiateStreaming(response, {
      env: {
        __exclosured_emit: (eventPtr, eventLen, payloadPtr, payloadLen) => {
          const event = this._readString(eventPtr, eventLen);
          const payload = this._readString(payloadPtr, payloadLen);
          this.pushEvent("wasm:emit", {
            module: name,
            event: event,
            payload: JSON.parse(payload),
          });
        },

        __exclosured_broadcast: (
          channelPtr,
          channelLen,
          dataPtr,
          dataLen
        ) => {
          const channel = this._readString(channelPtr, channelLen);
          const data = this._readString(dataPtr, dataLen);
          window.__exclosured_bus.dispatchEvent(
            new CustomEvent(channel, { detail: data })
          );
        },
      },
    });

    this.wasm = instance;
    this.memory = instance.exports.memory;

    // Listen for call requests from LiveView
    this.handleEvent("wasm:call", ({ func, args, ref }) => {
      try {
        const result = this._callWasm(func, args);
        this.pushEvent("wasm:result", {
          ref: ref,
          module: name,
          func: func,
          result: result,
        });
      } catch (e) {
        this.pushEvent("wasm:error", {
          ref: ref,
          module: name,
          func: func,
          error: e.message,
        });
      }
    });
  },

  async _mountInteractive(name) {
    const canvas = this.el.querySelector("canvas") || this._createCanvas();

    // wasm-bindgen modules have a JS glue file
    const wasm = await import(`/wasm/${name}/${name}.js`);
    await wasm.default(`/wasm/${name}/${name}_bg.wasm`);

    this.wasmBindgen = wasm;

    // Initialize with canvas if the module exports an init function
    if (wasm.init) {
      wasm.init(canvas);
    }

    // State sync: LiveView -> WASM (low frequency)
    this.handleEvent("wasm:state", (state) => {
      if (wasm.apply_state) {
        if (state.binary) {
          wasm.apply_state(new Uint8Array(state.binary));
        } else {
          const encoder = new TextEncoder();
          const encoded = encoder.encode(JSON.stringify(state));
          wasm.apply_state(encoded);
        }
      }
    });

    // Also support RPC calls for interactive modules
    this.handleEvent("wasm:call", ({ func, args, ref }) => {
      try {
        const fn = wasm[func];
        if (!fn) throw new Error(`Function '${func}' not exported`);
        const result = fn(...args);
        this.pushEvent("wasm:result", {
          ref: ref,
          module: name,
          func: func,
          result: result,
        });
      } catch (e) {
        this.pushEvent("wasm:error", {
          ref: ref,
          module: name,
          func: func,
          error: e.message,
        });
      }
    });
  },

  _setupSubscriptions() {
    const subscribeAttr = this.el.dataset.wasmSubscribe;
    if (!subscribeAttr) return;

    const channels = subscribeAttr.split(",").map((s) => s.trim());
    channels.forEach((channel) => {
      const handler = (e) => {
        if (this._mode === "compute") {
          this._callWasm("on_broadcast", [channel, e.detail]);
        } else if (this.wasmBindgen && this.wasmBindgen.on_broadcast) {
          this.wasmBindgen.on_broadcast(channel, e.detail);
        }
      };
      window.__exclosured_bus.addEventListener(channel, handler);
      this._subscriptions.push({ channel, handler });
    });
  },

  _callWasm(func, args) {
    const fn = this.wasm.exports[func];
    if (!fn) throw new Error(`Function '${func}' not exported`);

    // For string arguments, allocate in WASM memory
    const wasmArgs = args.map((arg) => {
      if (typeof arg === "string") {
        const { ptr, len } = this._writeString(arg);
        return [ptr, len];
      }
      return [arg];
    });

    // Flatten the args (ptr/len pairs become two args each)
    const flatArgs = wasmArgs.flat();
    return fn(...flatArgs);
  },

  _readString(ptr, len) {
    return new TextDecoder().decode(
      new Uint8Array(this.memory.buffer, ptr, len)
    );
  },

  _writeString(str) {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(str);
    const ptr = this.wasm.exports.alloc(bytes.length);
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  },

  _createCanvas() {
    const canvas = document.createElement("canvas");
    canvas.width = this.el.dataset.wasmWidth || 800;
    canvas.height = this.el.dataset.wasmHeight || 600;
    this.el.appendChild(canvas);
    return canvas;
  },

  destroyed() {
    // Clean up subscriptions
    this._subscriptions.forEach(({ channel, handler }) => {
      window.__exclosured_bus.removeEventListener(channel, handler);
    });
    this._subscriptions = [];

    this.wasm = null;
    this.wasmBindgen = null;
    this.memory = null;
  },
};

export { ExclosuredHook };
export default ExclosuredHook;
