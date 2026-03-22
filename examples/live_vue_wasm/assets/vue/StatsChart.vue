<template>
  <div class="stats-dashboard">
    <div class="chart-area">
      <div class="chart-title">Sensor Data (last {{ dataValues.length }} readings)</div>
      <canvas ref="chartCanvas"></canvas>
    </div>

    <div class="stats-grid">
      <div class="stat-card">
        <span class="stat-label">Count</span>
        <span class="stat-value count">{{ stats.count }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">Mean</span>
        <span class="stat-value mean">{{ stats.mean }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">Min</span>
        <span class="stat-value min-val">{{ stats.min }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">Max</span>
        <span class="stat-value max-val">{{ stats.max }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">Std Dev</span>
        <span class="stat-value stddev">{{ stats.std_dev }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">P50</span>
        <span class="stat-value p50">{{ stats.p50 }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">P90</span>
        <span class="stat-value p90">{{ stats.p90 }}</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">P99</span>
        <span class="stat-value p99">{{ stats.p99 }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, watch, onMounted, onUnmounted, computed } from "vue";
import { useLiveVue } from "live_vue";

const props = defineProps({
  data: { type: String, default: "[]" },
  running: { type: Boolean, default: false },
});

const live = useLiveVue();

const chartCanvas = ref(null);

// WASM module reference (raw wasm exports from wasm-bindgen init)
let wasmExports = null;
let wasmReady = false;

// Reactive stats state
const stats = ref({
  count: 0,
  mean: "0.00",
  min: "0.00",
  max: "0.00",
  std_dev: "0.00",
  p50: "0.00",
  p90: "0.00",
  p99: "0.00",
});

// Parse the JSON data string into an array of numbers
const dataValues = computed(() => {
  try {
    return JSON.parse(props.data);
  } catch {
    return [];
  }
});

// Load the WASM module on mount
onMounted(async () => {
  try {
    const wasmName = "live_vue_wasm_web_stats";
    const wasmJsUrl = `/wasm/${wasmName}/${wasmName}.js`;
    const wasmBgUrl = `/wasm/${wasmName}/${wasmName}_bg.wasm`;
    const mod = await import(/* @vite-ignore */ wasmJsUrl);
    wasmExports = await mod.default(wasmBgUrl);
    wasmReady = true;
    // Notify LiveView that WASM is ready
    live.pushEvent("wasm:ready", {});
    // Compute initial stats if data is already present
    if (dataValues.value.length > 0) {
      computeStats(dataValues.value);
      drawChart(dataValues.value);
    }
  } catch (err) {
    console.error("Failed to load WASM module:", err);
  }
});

/**
 * Send data to WASM for stats computation.
 *
 * The inline WASM function `compute_stats` takes (ptr, len) pointing to
 * a UTF-8 JSON array of f64 values. It parses the array, computes statistics,
 * and writes the result JSON back into the same buffer, returning the length
 * of the result string.
 */
function computeStats(values) {
  if (!wasmReady || !wasmExports) return;

  const jsonStr = JSON.stringify(values);
  const encoder = new TextEncoder();
  const encoded = encoder.encode(jsonStr);

  // Allocate a buffer large enough for both input and output JSON.
  // The output stats JSON can be much larger than the input array.
  const bufLen = Math.max(encoded.length * 2, 1024);
  const ptr = wasmExports.alloc(bufLen);

  // Zero the buffer then write input (alloc returns uninitialized memory)
  const mem = new Uint8Array(wasmExports.memory.buffer, ptr, bufLen);
  mem.fill(0);
  mem.set(encoded);

  // Pass the full buffer size so Rust has room to write the result back
  const resultLen = wasmExports.compute_stats(ptr, bufLen);

  // Read the result JSON from the same buffer
  const resultBytes = new Uint8Array(
    wasmExports.memory.buffer,
    ptr,
    resultLen
  );
  const decoder = new TextDecoder();
  const resultStr = decoder.decode(resultBytes);

  // Free the WASM buffer
  wasmExports.dealloc(ptr, bufLen);

  try {
    const parsed = JSON.parse(resultStr);
    stats.value = {
      count: parsed.count ?? 0,
      mean: (parsed.mean ?? 0).toFixed(2),
      min: (parsed.min ?? 0).toFixed(2),
      max: (parsed.max ?? 0).toFixed(2),
      std_dev: (parsed.std_dev ?? 0).toFixed(2),
      p50: (parsed.p50 ?? 0).toFixed(2),
      p90: (parsed.p90 ?? 0).toFixed(2),
      p99: (parsed.p99 ?? 0).toFixed(2),
    };
  } catch (e) {
    console.error("Failed to parse WASM stats result:", resultStr, e);
  }
}

/**
 * Draw a line chart on the canvas.
 */
function drawChart(values) {
  const canvas = chartCanvas.value;
  if (!canvas) return;

  const ctx = canvas.getContext("2d");
  const dpr = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();

  // Set canvas resolution to match display size
  canvas.width = rect.width * dpr;
  canvas.height = rect.height * dpr;
  ctx.scale(dpr, dpr);

  const w = rect.width;
  const h = rect.height;
  const padding = { top: 10, right: 10, bottom: 25, left: 45 };
  const chartW = w - padding.left - padding.right;
  const chartH = h - padding.top - padding.bottom;

  // Clear canvas
  ctx.clearRect(0, 0, w, h);

  if (values.length < 2) {
    ctx.fillStyle = "#666";
    ctx.font = "14px system-ui";
    ctx.textAlign = "center";
    ctx.fillText("Waiting for data...", w / 2, h / 2);
    return;
  }

  // Calculate value range
  const minVal = Math.min(...values);
  const maxVal = Math.max(...values);
  const range = maxVal - minVal || 1;
  const yMin = minVal - range * 0.1;
  const yMax = maxVal + range * 0.1;
  const yRange = yMax - yMin;

  // Draw grid lines and Y-axis labels
  ctx.strokeStyle = "#2a2a40";
  ctx.lineWidth = 1;
  ctx.fillStyle = "#666";
  ctx.font = "11px system-ui";
  ctx.textAlign = "right";

  const gridLines = 5;
  for (let i = 0; i <= gridLines; i++) {
    const y = padding.top + (chartH * i) / gridLines;
    const val = yMax - (yRange * i) / gridLines;

    ctx.beginPath();
    ctx.moveTo(padding.left, y);
    ctx.lineTo(w - padding.right, y);
    ctx.stroke();

    ctx.fillText(val.toFixed(1), padding.left - 6, y + 4);
  }

  // Draw the data line
  ctx.beginPath();
  ctx.strokeStyle = "#66d9ef";
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";

  for (let i = 0; i < values.length; i++) {
    const x = padding.left + (i / (values.length - 1)) * chartW;
    const y = padding.top + ((yMax - values[i]) / yRange) * chartH;

    if (i === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  ctx.stroke();

  // Draw gradient fill under the line
  const gradient = ctx.createLinearGradient(0, padding.top, 0, h - padding.bottom);
  gradient.addColorStop(0, "rgba(102, 217, 239, 0.25)");
  gradient.addColorStop(1, "rgba(102, 217, 239, 0.02)");

  ctx.beginPath();
  for (let i = 0; i < values.length; i++) {
    const x = padding.left + (i / (values.length - 1)) * chartW;
    const y = padding.top + ((yMax - values[i]) / yRange) * chartH;

    if (i === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  // Close the fill path along the bottom
  ctx.lineTo(
    padding.left + ((values.length - 1) / (values.length - 1)) * chartW,
    h - padding.bottom
  );
  ctx.lineTo(padding.left, h - padding.bottom);
  ctx.closePath();
  ctx.fillStyle = gradient;
  ctx.fill();

  // Draw mean line
  if (stats.value.count > 0) {
    const meanY =
      padding.top + ((yMax - parseFloat(stats.value.mean)) / yRange) * chartH;
    ctx.beginPath();
    ctx.strokeStyle = "rgba(166, 226, 46, 0.5)";
    ctx.lineWidth = 1;
    ctx.setLineDash([5, 5]);
    ctx.moveTo(padding.left, meanY);
    ctx.lineTo(w - padding.right, meanY);
    ctx.stroke();
    ctx.setLineDash([]);

    // Label the mean line
    ctx.fillStyle = "#a6e22e";
    ctx.font = "10px system-ui";
    ctx.textAlign = "left";
    ctx.fillText("mean", w - padding.right + 2, meanY + 3);
  }

  // Draw X-axis label
  ctx.fillStyle = "#555";
  ctx.font = "10px system-ui";
  ctx.textAlign = "center";
  ctx.fillText("time", w / 2, h - 4);
}

// Watch for data changes and recompute stats + redraw chart
watch(
  dataValues,
  (newValues) => {
    if (newValues.length > 0) {
      computeStats(newValues);
      drawChart(newValues);
    }
  },
  { immediate: true }
);

// Handle window resize
let resizeObserver = null;
onMounted(() => {
  if (chartCanvas.value) {
    resizeObserver = new ResizeObserver(() => {
      drawChart(dataValues.value);
    });
    resizeObserver.observe(chartCanvas.value);
  }
});

onUnmounted(() => {
  if (resizeObserver) {
    resizeObserver.disconnect();
  }
});
</script>
