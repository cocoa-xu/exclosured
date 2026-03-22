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

    if (!name) {
      console.error("Exclosured: data-wasm-module attribute is required");
      return;
    }

    this._name = name;
    this._subscriptions = [];

    try {
      // Set up the global namespace that wasm-bindgen imported functions
      // will call into (emit_event, broadcast_event).
      //
      // LIMITATION: wasm-bindgen's js_namespace imports resolve
      // `window.__exclosured` at call time, not at init time. When
      // multiple WASM modules are loaded on the same page, the last
      // mounted hook overwrites this global. All modules will then
      // route their emit/broadcast calls through that hook's pushEvent.
      // The `module` field in the payload is still set correctly per
      // hook, and for single-LiveView pages this is harmless. For
      // multi-LiveView pages, consider using a single WASM crate
      // (Cargo workspace) that bundles all functions.
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

      // Import the wasm-bindgen JS glue and initialize the WASM module
      const jsUrl = `/wasm/${name}/${name}.js`;
      const wasmUrl = `/wasm/${name}/${name}_bg.wasm`;
      const mod = await import(jsUrl);
      await mod.default(wasmUrl);
      this.wasmBindgen = mod;

      // Initialize with canvas if the module exports an init function
      if (mod.init) {
        const canvas = this.el.querySelector("canvas") || this._createCanvas();
        mod.init(canvas);
      }

      // State sync: LiveView -> WASM
      this.handleEvent("wasm:state", (state) => {
        if (this.wasmBindgen && this.wasmBindgen.apply_state) {
          if (state.binary) {
            this.wasmBindgen.apply_state(new Uint8Array(state.binary));
          } else {
            const encoder = new TextEncoder();
            const encoded = encoder.encode(JSON.stringify(state));
            this.wasmBindgen.apply_state(encoded);
          }
        }
      });

      // Handle RPC calls from LiveView
      this.handleEvent("wasm:call", ({ func, args, ref }) => {
        try {
          const wasmFn = this.wasmBindgen[func];
          if (!wasmFn) throw new Error(`Function '${func}' not exported`);
          const result = wasmFn(...args);
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

      // Set up inter-module subscriptions
      this._setupSubscriptions();

      // Apply initial sync data if present
      this._applySyncData();

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

  _setupSubscriptions() {
    const subscribeAttr = this.el.dataset.wasmSubscribe;
    if (!subscribeAttr) return;

    const channels = subscribeAttr.split(",").map((s) => s.trim());
    channels.forEach((channel) => {
      const handler = (e) => {
        if (this.wasmBindgen && this.wasmBindgen.on_broadcast) {
          this.wasmBindgen.on_broadcast(channel, e.detail);
        }
      };
      window.__exclosured_bus.addEventListener(channel, handler);
      this._subscriptions.push({ channel, handler });
    });
  },

  // Declarative state sync: when LiveView re-renders the component with
  // new sync data, this callback fires and pushes the update to WASM.
  updated() {
    this._applySyncData();
  },

  _applySyncData() {
    const syncAttr = this.el.dataset.wasmSync;
    if (!syncAttr || !this.wasmBindgen) return;

    // Only push if the data actually changed
    if (syncAttr === this._lastSyncData) return;
    this._lastSyncData = syncAttr;

    try {
      const state = JSON.parse(syncAttr);
      if (this.wasmBindgen.apply_state) {
        const encoder = new TextEncoder();
        this.wasmBindgen.apply_state(encoder.encode(JSON.stringify(state)));
      }
    } catch (e) {
      console.error("Exclosured: invalid sync data", e);
    }
  },

  _createCanvas() {
    const canvas = document.createElement("canvas");
    canvas.width = this.el.dataset.wasmWidth || 800;
    canvas.height = this.el.dataset.wasmHeight || 600;
    this.el.appendChild(canvas);
    return canvas;
  },

  destroyed() {
    // Clean up inter-module broadcast subscriptions
    this._subscriptions.forEach(({ channel, handler }) => {
      window.__exclosured_bus.removeEventListener(channel, handler);
    });
    this._subscriptions = [];

    // Call the WASM module's cleanup function if it exports one
    if (this.wasmBindgen && typeof this.wasmBindgen.destroyed === "function") {
      try {
        this.wasmBindgen.destroyed();
      } catch (e) {
        console.error("Exclosured: error in WASM destroyed() callback", e);
      }
    }

    // Note: handleEvent listeners registered via this.handleEvent() are
    // automatically cleaned up by Phoenix when the hook is destroyed.
    this.wasmBindgen = null;
  },
};

export { ExclosuredHook };
export default ExclosuredHook;
