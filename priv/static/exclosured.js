/**
 * Exclosured - Browser WASM loader
 *
 * Loads and manages WebAssembly modules compiled from Rust via Exclosured.
 * Supports both compute (RPC) and interactive (continuous rendering) modes.
 */

const ExclosuredLoader = {
  /**
   * Load a compute-mode WASM module (no wasm-bindgen).
   * Returns an object with the WASM instance and helper methods.
   */
  async loadCompute(url) {
    const response = fetch(url);
    const { instance } = await WebAssembly.instantiateStreaming(response, {
      env: this._buildEnv(null),
    });

    return {
      instance,
      memory: instance.exports.memory,

      call(func, ...args) {
        const fn = instance.exports[func];
        if (!fn) throw new Error(`Function '${func}' not exported`);
        return fn(...args);
      },

      writeString(str) {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(str);
        const ptr = instance.exports.alloc(bytes.length);
        new Uint8Array(instance.exports.memory.buffer, ptr, bytes.length).set(
          bytes
        );
        return { ptr, len: bytes.length };
      },

      readString(ptr, len) {
        return new TextDecoder().decode(
          new Uint8Array(instance.exports.memory.buffer, ptr, len)
        );
      },

      free(ptr, len) {
        if (instance.exports.dealloc) {
          instance.exports.dealloc(ptr, len);
        }
      },
    };
  },

  /**
   * Load an interactive-mode WASM module (with wasm-bindgen).
   * Imports the JS glue module and initializes with the background wasm.
   */
  async loadInteractive(jsUrl, wasmUrl) {
    const mod = await import(jsUrl);
    await mod.default(wasmUrl);
    return mod;
  },

  /**
   * Load a binary asset into WASM memory.
   * Returns { ptr, len } pointing to the data in WASM linear memory.
   */
  async loadAsset(wasmModule, assetUrl) {
    const response = await fetch(assetUrl);
    const bytes = new Uint8Array(await response.arrayBuffer());
    const ptr = wasmModule.instance.exports.alloc(bytes.length);
    new Uint8Array(
      wasmModule.instance.exports.memory.buffer,
      ptr,
      bytes.length
    ).set(bytes);
    return { ptr, len: bytes.length };
  },

  _buildEnv(callbacks) {
    return {
      __exclosured_emit: (eventPtr, eventLen, payloadPtr, payloadLen) => {
        if (callbacks && callbacks.onEmit) {
          callbacks.onEmit(eventPtr, eventLen, payloadPtr, payloadLen);
        }
      },

      __exclosured_broadcast: (
        channelPtr,
        channelLen,
        dataPtr,
        dataLen
      ) => {
        if (callbacks && callbacks.onBroadcast) {
          callbacks.onBroadcast(channelPtr, channelLen, dataPtr, dataLen);
        }
      },
    };
  },
};

// Global message bus for inter-module communication
window.__exclosured_bus = window.__exclosured_bus || new EventTarget();

export { ExclosuredLoader };
