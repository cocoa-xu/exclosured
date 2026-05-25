export declare class WasmBuffer {
  readonly ptr: number;
  readonly len: number;
  readonly bytes: Uint8Array;

  free(): void;
}

export declare const ExclosuredLoader: {
  load(jsUrl: string, wasmUrl: string): Promise<Record<string, unknown>>;
  loadAsset(wasmModule: Record<string, unknown>, assetUrl: string): Promise<WasmBuffer>;
};
