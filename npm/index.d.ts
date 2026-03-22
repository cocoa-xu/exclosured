/**
 * Phoenix LiveView hook for Exclosured WASM modules.
 *
 * Usage:
 *   import { ExclosuredHook } from "exclosured";
 *   let liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { Exclosured: ExclosuredHook }
 *   });
 */
export declare const ExclosuredHook: {
  mounted(): Promise<void>;
  updated(): void;
  destroyed(): void;
};

export default ExclosuredHook;
