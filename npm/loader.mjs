/**
 * Exclosured standalone WASM loader (no LiveView required).
 *
 * Usage:
 *   import { ExclosuredLoader, WasmBuffer } from "exclosured/loader";
 *   const mod = await ExclosuredLoader.load("/wasm/my_mod/my_mod.js", "/wasm/my_mod/my_mod_bg.wasm");
 *   const buf = await ExclosuredLoader.loadAsset(mod, "/assets/data.bin");
 *   mod.process(buf.ptr, buf.len);
 *   buf.free(); // or let GC handle it automatically
 */

if (typeof window !== "undefined") {
  window.__exclosured_bus = window.__exclosured_bus || new EventTarget();
}

const _wasmFinalizer =
  typeof FinalizationRegistry !== "undefined"
    ? new FinalizationRegistry(({ dealloc, ptr, len }) => {
        try { dealloc(ptr, len); } catch (_) {}
      })
    : null;

export class WasmBuffer {
  constructor(memory, dealloc, ptr, len) {
    this._memory = memory;
    this._dealloc = dealloc;
    this.ptr = ptr;
    this.len = len;
    this._freed = false;
    if (_wasmFinalizer) _wasmFinalizer.register(this, { dealloc, ptr, len }, this);
  }

  get bytes() {
    if (this._freed) throw new Error("WasmBuffer already freed");
    return new Uint8Array(this._memory.buffer, this.ptr, this.len);
  }

  free() {
    if (this._freed) return;
    this._freed = true;
    try { this._dealloc(this.ptr, this.len); } catch (_) {}
    if (_wasmFinalizer) _wasmFinalizer.unregister(this);
  }
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
    if (!wasmModule.alloc) throw new Error("Module does not export alloc");
    const ptr = wasmModule.alloc(bytes.length);
    new Uint8Array(wasmModule.memory.buffer, ptr, bytes.length).set(bytes);
    return new WasmBuffer(wasmModule.memory, wasmModule.dealloc, ptr, bytes.length);
  },
};
