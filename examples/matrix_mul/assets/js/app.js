import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// ========== Helpers ==========

function yieldUI() { return new Promise(r => setTimeout(r, 0)); }

function median(arr) {
  const s = [...arr].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function formatTime(ms) {
  if (ms < 1) return ms.toFixed(3) + " ms";
  if (ms < 1000) return ms.toFixed(1) + " ms";
  return (ms / 1000).toFixed(2) + " s";
}

function formatGflops(g) {
  if (g < 0.001) return g.toExponential(2);
  return g < 1 ? g.toFixed(3) : g.toFixed(2);
}

function formatChecksum(v) {
  return v == null ? "N/A" : v.toFixed(4);
}

function generateMatrix(n, prec) {
  const size = n * n;
  if (prec === "i8") {
    const m = new Int8Array(size);
    for (let i = 0; i < size; i++) m[i] = Math.floor(Math.random() * 21) - 10;
    return m;
  }
  if (prec === "i16") {
    const m = new Int16Array(size);
    for (let i = 0; i < size; i++) m[i] = Math.floor(Math.random() * 201) - 100;
    return m;
  }
  if (prec === "i32") {
    const m = new Int32Array(size);
    for (let i = 0; i < size; i++) m[i] = Math.floor(Math.random() * 201) - 100;
    return m;
  }
  if (prec === "f32") {
    const m = new Float32Array(size);
    for (let i = 0; i < size; i++) m[i] = Math.random() * 2 - 1;
    return m;
  }
  const m = new Float64Array(size);
  for (let i = 0; i < size; i++) m[i] = Math.random() * 2 - 1;
  return m;
}

function arraySum(arr) {
  let s = 0;
  for (let i = 0; i < arr.length; i++) s += arr[i];
  return s;
}

function setLoad(id, ok, text) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.className = "load-item " + (ok === true ? "ready" : ok === false ? "failed" : "");
}

function setStep(id, state, text) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = "progress-step " + state;
  el.textContent = text;
}

// ========== 1. JavaScript ==========

function jsMatmul(a, b, n) {
  const c = new Float64Array(n * n);
  for (let i = 0; i < n; i++)
    for (let j = 0; j < n; j++) {
      let s = 0;
      for (let k = 0; k < n; k++) s += a[i * n + k] * b[k * n + j];
      c[i * n + j] = s;
    }
  return c;
}

// ========== 2. WASM (nalgebra) ==========

let wasmMod = null;

async function loadWasm() {
  try {
    const name = "matrix_mul_web_multiplier";
    const mod = await import(`/wasm/${name}/${name}.js`);
    wasmMod = await mod.default(`/wasm/${name}/${name}_bg.wasm`);
    setLoad("load-wasm", true, "WASM: ready");
    const st = document.getElementById("wasm-status");
    if (st) { st.textContent = "WASM Ready"; st.className = "badge badge-ready"; }
  } catch (e) {
    console.error("WASM load failed:", e);
    setLoad("load-wasm", false, "WASM: failed");
  }
}

function wasmMatmul(a, b, n, prec) {
  if (!wasmMod) return null;
  const size = n * n;
  const config = {
    f64: { fn: "matmul",     elSize: 8, Arr: Float64Array, resLen: 8,
           read: (p) => new DataView(wasmMod.memory.buffer, p, 8).getFloat64(0, true) },
    f32: { fn: "matmul_f32", elSize: 4, Arr: Float32Array, resLen: 4,
           read: (p) => new DataView(wasmMod.memory.buffer, p, 4).getFloat32(0, true) },
    i32: { fn: "matmul_i32", elSize: 4, Arr: Int32Array,   resLen: 8,
           read: (p) => Number(new DataView(wasmMod.memory.buffer, p, 8).getBigInt64(0, true)) },
    i16: { fn: "matmul_i16", elSize: 2, Arr: Int16Array,   resLen: 8,
           read: (p) => Number(new DataView(wasmMod.memory.buffer, p, 8).getBigInt64(0, true)) },
    i8:  { fn: "matmul_i8",  elSize: 1, Arr: Uint8Array,   resLen: 8,
           read: (p) => Number(new DataView(wasmMod.memory.buffer, p, 8).getBigInt64(0, true)) },
  }[prec];
  if (!config || !wasmMod[config.fn]) return null;

  const bufSize = 2 * size * config.elSize;
  const ptr = wasmMod.alloc(bufSize);
  const mem = new Uint8Array(wasmMod.memory.buffer, ptr, bufSize);

  if (prec === "i8") {
    const combined = new Uint8Array(2 * size);
    combined.set(new Uint8Array(a.buffer, a.byteOffset, size), 0);
    combined.set(new Uint8Array(b.buffer, b.byteOffset, size), size);
    mem.set(combined, 0);
  } else {
    const combined = new config.Arr(2 * size);
    combined.set(a, 0); combined.set(b, size);
    mem.set(new Uint8Array(combined.buffer), 0);
  }

  const resultLen = wasmMod[config.fn](ptr, bufSize, n);
  let checksum = null;
  if (resultLen === config.resLen) checksum = config.read(ptr);
  wasmMod.dealloc(ptr, bufSize);
  return checksum;
}

// ========== 3. WebGPU ==========

let gpuDevice = null;

const GPU_SHADER_F32 = `
@group(0) @binding(0) var<storage, read> a: array<f32>;
@group(0) @binding(1) var<storage, read> b: array<f32>;
@group(0) @binding(2) var<storage, read_write> c: array<f32>;
@group(0) @binding(3) var<uniform> uniforms: vec4<u32>;
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let n = uniforms.x; let row = id.x; let col = id.y;
    if (row >= n || col >= n) { return; }
    var s: f32 = 0.0;
    for (var k: u32 = 0u; k < n; k++) { s += a[row * n + k] * b[k * n + col]; }
    c[row * n + col] = s;
}`;

const GPU_SHADER_I32 = `
@group(0) @binding(0) var<storage, read> a: array<i32>;
@group(0) @binding(1) var<storage, read> b: array<i32>;
@group(0) @binding(2) var<storage, read_write> c: array<i32>;
@group(0) @binding(3) var<uniform> uniforms: vec4<u32>;
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let n = uniforms.x; let row = id.x; let col = id.y;
    if (row >= n || col >= n) { return; }
    var s: i32 = 0;
    for (var k: u32 = 0u; k < n; k++) { s += a[row * n + k] * b[k * n + col]; }
    c[row * n + col] = s;
}`;

async function initGPU() {
  if (!navigator.gpu) { setLoad("load-gpu", false, "WebGPU: not supported"); return; }
  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) { setLoad("load-gpu", false, "WebGPU: no adapter"); return; }
    gpuDevice = await adapter.requestDevice();
    setLoad("load-gpu", true, "WebGPU: ready");
  } catch (e) {
    setLoad("load-gpu", false, "WebGPU: failed");
  }
}

async function gpuMatmul(a, b, n, prec) {
  if (!gpuDevice) return null;
  const size = n * n, bytes = size * 4;
  const useI32 = prec === "i32" || prec === "i16" || prec === "i8";
  const shader = useI32 ? GPU_SHADER_I32 : GPU_SHADER_F32;

  // Prepare typed arrays for upload
  let aArr, bArr, ResultArr;
  if (useI32) {
    aArr = new Int32Array(size);
    bArr = new Int32Array(size);
    for (let i = 0; i < size; i++) { aArr[i] = a[i]; bArr[i] = b[i]; }
    ResultArr = Int32Array;
  } else {
    aArr = new Float32Array(size);
    bArr = new Float32Array(size);
    for (let i = 0; i < size; i++) { aArr[i] = a[i]; bArr[i] = b[i]; }
    ResultArr = Float32Array;
  }

  const bufA = gpuDevice.createBuffer({ size: bytes, usage: GPUBufferUsage.STORAGE, mappedAtCreation: true });
  new ResultArr(bufA.getMappedRange()).set(aArr); bufA.unmap();
  const bufB = gpuDevice.createBuffer({ size: bytes, usage: GPUBufferUsage.STORAGE, mappedAtCreation: true });
  new ResultArr(bufB.getMappedRange()).set(bArr); bufB.unmap();
  const bufC = gpuDevice.createBuffer({ size: bytes, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
  const bufRead = gpuDevice.createBuffer({ size: bytes, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
  const bufUni = gpuDevice.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
  new Uint32Array(bufUni.getMappedRange()).set([n, 0, 0, 0]); bufUni.unmap();

  const pipeline = gpuDevice.createComputePipeline({
    layout: "auto",
    compute: { module: gpuDevice.createShaderModule({ code: shader }), entryPoint: "main" },
  });
  const bindGroup = gpuDevice.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: bufA } }, { binding: 1, resource: { buffer: bufB } },
      { binding: 2, resource: { buffer: bufC } }, { binding: 3, resource: { buffer: bufUni } },
    ],
  });
  const wg = Math.ceil(n / 16);
  const enc = gpuDevice.createCommandEncoder();
  const pass = enc.beginComputePass();
  pass.setPipeline(pipeline); pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(wg, wg); pass.end();
  enc.copyBufferToBuffer(bufC, 0, bufRead, 0, bytes);
  gpuDevice.queue.submit([enc.finish()]);

  await bufRead.mapAsync(GPUMapMode.READ);
  const result = new ResultArr(bufRead.getMappedRange()).slice();
  bufRead.unmap();
  [bufA, bufB, bufC, bufRead, bufUni].forEach(b => b.destroy());
  return arraySum(result);
}

// ========== 4. TensorFlow.js ==========

let tfReady = false;

async function initTF() {
  try {
    if (typeof tf === "undefined") { setLoad("load-tf", false, "TF.js: not loaded"); return; }
    await tf.ready();
    tfReady = true;
    setLoad("load-tf", true, `TF.js: ready (${tf.getBackend()})`);
  } catch (e) {
    setLoad("load-tf", false, "TF.js: failed");
  }
}

async function tfMatmul(a, b, n) {
  if (!tfReady) return null;
  const size = n * n;
  const aF32 = new Float32Array(size), bF32 = new Float32Array(size);
  for (let i = 0; i < size; i++) { aF32[i] = a[i]; bF32[i] = b[i]; }
  const ta = tf.tensor2d(aF32, [n, n]);
  const tb = tf.tensor2d(bF32, [n, n]);
  const tc = tf.matMul(ta, tb);
  const data = await tc.data();
  const checksum = arraySum(data);
  ta.dispose(); tb.dispose(); tc.dispose();
  return checksum;
}

// ========== 5. OpenCV.js ==========

let cvReady = false;

function initCV() {
  return new Promise((resolve) => {
    if (typeof cv !== "undefined" && cv.Mat) {
      cvReady = true; setLoad("load-cv", true, "OpenCV: ready"); resolve(); return;
    }
    const check = setInterval(() => {
      if (typeof cv !== "undefined" && cv.Mat) {
        clearInterval(check); cvReady = true; setLoad("load-cv", true, "OpenCV: ready"); resolve();
      }
    }, 200);
    setTimeout(() => { clearInterval(check); if (!cvReady) { setLoad("load-cv", false, "OpenCV: timeout"); resolve(); } }, 30000);
  });
}

function cvMatmul(a, b, n, useF32) {
  if (!cvReady) return null;
  const size = n * n;
  let matA, matB, getData;
  if (useF32) {
    const aF = new Float32Array(size), bF = new Float32Array(size);
    for (let i = 0; i < size; i++) { aF[i] = a[i]; bF[i] = b[i]; }
    matA = cv.matFromArray(n, n, cv.CV_32F, aF);
    matB = cv.matFromArray(n, n, cv.CV_32F, bF);
    getData = m => m.data32F;
  } else {
    matA = cv.matFromArray(n, n, cv.CV_64F, Float64Array.from(a));
    matB = cv.matFromArray(n, n, cv.CV_64F, Float64Array.from(b));
    getData = m => m.data64F;
  }
  const matC = new cv.Mat(), empty = new cv.Mat();
  cv.gemm(matA, matB, 1, empty, 0, matC);
  const checksum = arraySum(getData(matC));
  matA.delete(); matB.delete(); matC.delete(); empty.delete();
  return checksum;
}

// ========== Engine config ==========

const ENGINES = [
  { id: "js",   name: "JavaScript",    sub: "triple nested loop", color: "c-js",   step: "step-js" },
  { id: "wasm", name: "WASM",          sub: "Rust nalgebra",      color: "c-wasm", step: "step-wasm" },
  { id: "gpu",  name: "WebGPU",        sub: "compute shader",     color: "c-gpu",  step: "step-gpu" },
  { id: "tf",   name: "TensorFlow.js", sub: "auto backend",       color: "c-tf",   step: "step-tf" },
  { id: "cv",   name: "OpenCV.js",     sub: "cv.gemm",            color: "c-cv",   step: "step-cv" },
];

const ENGINE_SUPPORT = {
  js: ["f32", "f64", "i32", "i16", "i8"], wasm: ["f32", "f64", "i32", "i16", "i8"],
  gpu: ["f32", "i32", "i16", "i8"], tf: ["f32"], cv: ["f32", "f64"],
};

function isAvailable(engine) {
  return { js: true, wasm: !!wasmMod, gpu: !!gpuDevice, tf: tfReady, cv: cvReady }[engine.id];
}

function isAvailableForPrec(engine, prec) {
  return isAvailable(engine) && (ENGINE_SUPPORT[engine.id]?.includes(prec) ?? false);
}

async function runEngine(engine, a, b, n, prec) {
  switch (engine.id) {
    case "js":   return { checksum: arraySum(jsMatmul(a, b, n)), precision: prec };
    case "wasm": return { checksum: wasmMatmul(a, b, n, prec), precision: prec };
    case "gpu":  { const p = ["i32","i16","i8"].includes(prec) ? prec : "f32"; return { checksum: await gpuMatmul(a, b, n, prec), precision: p }; }
    case "tf":   return { checksum: await tfMatmul(a, b, n), precision: "f32" };
    case "cv":   { const f32 = prec !== "f64"; return { checksum: cvMatmul(a, b, n, f32), precision: f32 ? "f32" : "f64" }; }
  }
}

// ========== Results rendering ==========

function renderResultsTable(results) {
  const tbody = document.getElementById("results-body");
  const table = document.getElementById("results-table");
  const available = results.filter(r => r.available && r.timeMs > 0);
  const fastest = available.length ? Math.min(...available.map(r => r.timeMs)) : 0;

  tbody.innerHTML = results.map(r => {
    const best = r.available && r.timeMs > 0 && r.timeMs === fastest;
    if (!r.available) {
      return `<tr><td><span class="engine-name ${r.engine.color}">${r.engine.name}</span>
        <span class="engine-sub">${r.engine.sub}</span></td>
        <td class="val-na">${r.reason || "N/A"}</td><td class="val-na">-</td><td class="val-na">-</td><td class="val-na">-</td></tr>`;
    }
    return `<tr class="${best ? "winner-row" : ""}">
      <td>${best ? '<span class="crown">&#x1F451;</span>' : ""}<span class="engine-name ${r.engine.color}">${r.engine.name}</span>
        <span class="engine-sub">${r.engine.sub}</span></td>
      <td class="val ${r.engine.color}">${formatTime(r.timeMs)}</td>
      <td class="val ${r.engine.color}">${formatGflops(r.gflops)}</td>
      <td class="val">${formatChecksum(r.checksum)}</td>
      <td>${r.precision}</td></tr>`;
  }).join("");
  table.style.display = "table";

  // Winner banner
  const winner = document.getElementById("winner");
  if (available.length >= 2) {
    const sorted = [...available].sort((a, b) => a.timeMs - b.timeMs);
    const b = sorted[0], w = sorted[sorted.length - 1];
    const colors = { js: "#f9ca24", wasm: "#7bed9f", gpu: "#a29bfe", tf: "#ff6b6b", cv: "#ffa502" };
    const c = colors[b.engine.id] || "#eee";
    winner.style.display = "block";
    winner.style.background = `${c}15`; winner.style.border = `1px solid ${c}50`; winner.style.color = c;
    winner.textContent = `${b.engine.name} wins -- ${(w.timeMs / b.timeMs).toFixed(1)}x faster than ${w.engine.name} (${formatTime(b.timeMs)} vs ${formatTime(w.timeMs)})`;
  } else {
    winner.style.display = "none";
  }
}

// ========== Benchmark runner ==========

const ITERATIONS = 3;
let selectedN = 256;
let selectedPrec = "f32";
let running = false;
let stopRequested = false;

async function runBenchmark() {
  if (running) return;
  running = true;
  stopRequested = false;

  const runBtn = document.getElementById("run-btn");
  const stopBtn = document.getElementById("stop-btn");
  if (runBtn) runBtn.style.display = "none";
  if (stopBtn) stopBtn.style.display = "inline-block";

  const n = selectedN, prec = selectedPrec, flops = 2 * n * n * n;

  document.getElementById("progress").style.display = "flex";
  document.getElementById("winner").style.display = "none";
  for (const e of ENGINES) setStep(e.step, "", e.name + ": waiting");
  setStep("step-gen", "active", "Generating...");
  await yieldUI();

  const a = generateMatrix(n, prec);
  const b = generateMatrix(n, prec);
  setStep("step-gen", "done", `2x ${n}x${n} (${prec})`);

  const results = [];

  for (const engine of ENGINES) {
    if (stopRequested) {
      setStep(engine.step, "skip", engine.name + ": stopped");
      results.push({ engine, available: false, reason: "stopped", timeMs: 0, gflops: 0, checksum: null, precision: "-" });
      continue;
    }
    if (!isAvailableForPrec(engine, prec)) {
      const reason = !isAvailable(engine) ? "N/A" : `no ${prec}`;
      setStep(engine.step, "skip", engine.name + ": " + reason);
      results.push({ engine, available: false, reason, timeMs: 0, gflops: 0, checksum: null, precision: "-" });
      renderResultsTable(results);
      continue;
    }

    const times = [];
    let last = null, stopped = false;
    for (let iter = 0; iter < ITERATIONS; iter++) {
      if (stopRequested) { stopped = true; break; }
      setStep(engine.step, "active", `${engine.name}: ${iter + 1}/${ITERATIONS}`);
      await yieldUI();
      const t0 = performance.now();
      last = await runEngine(engine, a, b, n, prec);
      const t1 = performance.now();
      times.push(t1 - t0);
    }

    if (times.length > 0) {
      const med = median(times);
      const gflops = flops / (med / 1000) / 1e9;
      setStep(engine.step, stopped ? "skip" : "done",
        `${engine.name}: ${formatTime(med)}${stopped ? " (partial)" : ""}`);
      results.push({ engine, available: true, timeMs: med, gflops,
        checksum: last?.checksum ?? null, precision: last?.precision ?? "-" });
    } else {
      setStep(engine.step, "skip", engine.name + ": stopped");
      results.push({ engine, available: false, reason: "stopped", timeMs: 0, gflops: 0, checksum: null, precision: "-" });
    }

    // Incremental table update after each engine
    renderResultsTable(results);
    await yieldUI();
  }

  running = false;
  stopRequested = false;
  if (runBtn) runBtn.style.display = "inline-block";
  if (stopBtn) stopBtn.style.display = "none";
}

// ========== Init ==========

document.addEventListener("DOMContentLoaded", async () => {
  document.querySelectorAll(".size-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".size-btn").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      selectedN = parseInt(btn.dataset.n);
    });
  });
  document.querySelectorAll(".prec-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".prec-btn").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      selectedPrec = btn.dataset.prec;
    });
  });

  const runBtn = document.getElementById("run-btn");
  const stopBtn = document.getElementById("stop-btn");

  await Promise.all([loadWasm(), initGPU(), initTF(), initCV()]);

  if (runBtn) { runBtn.disabled = false; runBtn.addEventListener("click", runBenchmark); }
  if (stopBtn) { stopBtn.addEventListener("click", () => { stopRequested = true; }); }
});

// ========== Phoenix ==========

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken } });
liveSocket.connect();
window.liveSocket = liveSocket;
