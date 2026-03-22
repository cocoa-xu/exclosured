/**
 * Exclosured standalone WASM loader (no LiveView required).
 *
 * Usage:
 *   import { ExclosuredLoader } from "exclosured/loader";
 *   const mod = await ExclosuredLoader.load("/wasm/my_mod/my_mod.js", "/wasm/my_mod/my_mod_bg.wasm");
 */

if (typeof window !== "undefined") {
  window.__exclosured_bus = window.__exclosured_bus || new EventTarget();
}

export const ExclosuredLoader = {
  async load(jsUrl, wasmUrl) {
    const mod = await import(jsUrl);
    await mod.default(wasmUrl);
    return mod;
  },

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
