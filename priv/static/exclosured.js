/**
 * Exclosured - Browser WASM loader
 *
 * Loads and manages WebAssembly modules compiled from Rust via Exclosured.
 * All modules use wasm-bindgen for JS interop.
 */

// Auto-cleanup registry: frees WASM memory when WasmBuffer is garbage collected.
const _wasmFinalizer =
  typeof FinalizationRegistry !== "undefined"
    ? new FinalizationRegistry(({ dealloc, ptr, len }) => {
        try {
          dealloc(ptr, len);
        } catch (_) {}
      })
    : null;

/**
 * A managed buffer in WASM linear memory.
 * Provides a typed view into the data and automatic cleanup.
 *
 * - Call `free()` for immediate, deterministic deallocation.
 * - If you forget, the FinalizationRegistry frees it during GC.
 * - After `free()`, accessing `bytes` throws.
 */
class WasmBuffer {
  constructor(memory, dealloc, ptr, len) {
    this._memory = memory;
    this._dealloc = dealloc;
    this.ptr = ptr;
    this.len = len;
    this._freed = false;

    // Register for automatic GC cleanup
    if (_wasmFinalizer) {
      _wasmFinalizer.register(this, { dealloc, ptr, len }, this);
    }
  }

  /** Typed view into the WASM linear memory. */
  get bytes() {
    if (this._freed) throw new Error("WasmBuffer already freed");
    return new Uint8Array(this._memory.buffer, this.ptr, this.len);
  }

  /** Free the WASM memory immediately. Safe to call multiple times. */
  free() {
    if (this._freed) return;
    this._freed = true;
    try {
      this._dealloc(this.ptr, this.len);
    } catch (_) {}
    // Unregister from finalizer since we already freed
    if (_wasmFinalizer) {
      _wasmFinalizer.unregister(this);
    }
  }
}

const ExclosuredLoader = {
  /**
   * Load a WASM module via its wasm-bindgen JS glue file.
   * Imports the JS glue module and initializes with the background wasm.
   */
  async load(jsUrl, wasmUrl) {
    const mod = await import(jsUrl);
    await mod.default(wasmUrl);
    return mod;
  },

  /**
   * Load a binary asset into WASM memory.
   *
   * Returns a `WasmBuffer` with:
   * - `.ptr` / `.len`: raw pointer and length for passing to WASM functions
   * - `.bytes`: Uint8Array view into the data
   * - `.free()`: immediately release the memory (also auto-freed on GC)
   *
   * @param {Object} wasmModule - A wasm-bindgen module with alloc/dealloc exports.
   * @param {string} assetUrl - URL of the binary asset to fetch and load.
   * @returns {Promise<WasmBuffer>} Managed buffer in WASM memory.
   */
  async loadAsset(wasmModule, assetUrl) {
    const response = await fetch(assetUrl);
    const bytes = new Uint8Array(await response.arrayBuffer());

    if (!wasmModule.alloc) {
      throw new Error("Module does not export alloc");
    }

    const ptr = wasmModule.alloc(bytes.length);
    const memory = wasmModule.memory;
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);

    return new WasmBuffer(memory, wasmModule.dealloc, ptr, bytes.length);
  },
};

// Global message bus for inter-module communication
window.__exclosured_bus = window.__exclosured_bus || new EventTarget();

export { ExclosuredLoader, WasmBuffer };
