export declare class WasmBuffer {
  readonly ptr: number;
  readonly len: number;
  readonly bytes: Uint8Array;

  free(): void;
}

export type ExclosuredWasmModule = Record<string, unknown>;

export declare const ExclosuredLoader: {
  load<TModule extends ExclosuredWasmModule = ExclosuredWasmModule>(
    jsUrl: string,
    wasmUrl: string
  ): Promise<TModule>;
  loadAsset(wasmModule: ExclosuredWasmModule, assetUrl: string): Promise<WasmBuffer>;
};
