/**
 * Exclosured - Browser WASM loader
 *
 * Loads and manages WebAssembly modules compiled from Rust via Exclosured.
 * All modules use wasm-bindgen for JS interop.
 */

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
   * Load a binary asset into WASM memory via the module's alloc export.
   * Returns { ptr, len } pointing to the data in WASM linear memory.
   */
  async loadAsset(wasmModule, assetUrl) {
    const response = await fetch(assetUrl);
    const bytes = new Uint8Array(await response.arrayBuffer());

    if (wasmModule.alloc) {
      const ptr = wasmModule.alloc(bytes.length);
      const memory = wasmModule.memory;
      new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
      return { ptr, len: bytes.length };
    }

    throw new Error("Module does not export alloc");
  },
};

// Global message bus for inter-module communication
window.__exclosured_bus = window.__exclosured_bus || new EventTarget();

export { ExclosuredLoader };
