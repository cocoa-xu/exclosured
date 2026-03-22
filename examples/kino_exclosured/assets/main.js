// Kino.Exclosured - WASM Data Explorer for Livebook
//
// This is the browser-side code for the Kino.JS widget.
// It renders a data table with column statistics, histograms,
// filtering, sorting, and pagination. When WASM is available,
// statistics and histograms are computed in WebAssembly.
// A JS fallback is included for environments where WASM
// has not been compiled yet.

export function init(ctx, payload) {
  ctx.importCSS("main.css");
  ctx.importCSS(
    "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap"
  );

  const root = ctx.root;
  const rows = JSON.parse(payload.rows);
  const columns = payload.columns;
  const title = payload.title;
  const pageSize = payload.page_size;

  let currentPage = 1;
  let sortColumn = null;
  let sortDirection = "asc";
  let activeFilters = JSON.parse(payload.active_filters || "{}");
  let selectedColumn = payload.selected_column || null;
  let wasmModule = null;
  // Track columns with pending local debounce to avoid remote overwrites mid-typing
  const pendingFilterCols = new Set();

  // Attempt to load the WASM stats module.
  async function tryLoadWasm() {
    try {
      const jsUrl = "/wasm/kino_exclosured_stats/kino_exclosured_stats.js";
      const wasmUrl =
        "/wasm/kino_exclosured_stats/kino_exclosured_stats_bg.wasm";
      const mod = await import(jsUrl);
      await mod.default(wasmUrl);
      wasmModule = mod;
      updateStatusBadge(true);
    } catch (_err) {
      // WASM not available; JS fallback will be used
      updateStatusBadge(false);
    }
  }

  // -- JS Fallback Statistics --

  function jsComputeStats(values) {
    if (values.length === 0) {
      return { count: 0, min: 0, max: 0, mean: 0, median: 0, std_dev: 0, p25: 0, p75: 0 };
    }

    const sorted = [...values].sort((a, b) => a - b);
    const count = sorted.length;
    const sum = sorted.reduce((a, b) => a + b, 0);
    const mean = sum / count;
    const min = sorted[0];
    const max = sorted[count - 1];

    const median =
      count % 2 === 0
        ? (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        : sorted[Math.floor(count / 2)];

    const variance = sorted.reduce((acc, v) => acc + (v - mean) ** 2, 0) / count;
    const std_dev = Math.sqrt(variance);

    const p25 = sorted[Math.floor(count * 0.25)];
    const p75 = sorted[Math.floor(count * 0.75)];

    return { count, min, max, mean, median, std_dev, p25, p75 };
  }

  function jsComputeHistogram(values, numBins) {
    if (values.length === 0) {
      return { bins: [], counts: [], min: 0, max: 0 };
    }

    const min = Math.min(...values);
    const max = Math.max(...values);
    const range = max - min;
    const binWidth = range === 0 ? 1 : range / numBins;

    const counts = new Array(numBins).fill(0);
    for (const v of values) {
      let idx = Math.floor((v - min) / binWidth);
      if (idx >= numBins) idx = numBins - 1;
      counts[idx]++;
    }

    const bins = [];
    for (let i = 0; i <= numBins; i++) {
      bins.push(min + i * binWidth);
    }

    return { bins, counts, min, max };
  }

  // -- WASM-backed statistics (with JS fallback) --

  function computeStats(values) {
    if (wasmModule && wasmModule.alloc) {
      try {
        const json = JSON.stringify(values);
        const encoded = new TextEncoder().encode(json);
        const bufSize = Math.max(encoded.length, 1024) * 2;
        const ptr = wasmModule.alloc(bufSize);
        const memory = wasmModule.memory;
        const view = new Uint8Array(memory.buffer, ptr, bufSize);
        view.fill(0);
        view.set(encoded);
        const resultLen = wasmModule.compute_stats(ptr, bufSize);
        const resultBytes = new Uint8Array(memory.buffer, ptr, resultLen);
        const resultStr = new TextDecoder().decode(resultBytes);
        wasmModule.dealloc(ptr, bufSize);
        return JSON.parse(resultStr);
      } catch (_e) {
        // Fall through to JS
      }
    }
    return jsComputeStats(values);
  }

  function computeHistogram(values, numBins) {
    if (wasmModule && wasmModule.alloc) {
      try {
        const input = JSON.stringify({ values, bins: numBins });
        const encoded = new TextEncoder().encode(input);
        const bufSize = Math.max(encoded.length, 2048) * 2;
        const ptr = wasmModule.alloc(bufSize);
        const memory = wasmModule.memory;
        const view = new Uint8Array(memory.buffer, ptr, bufSize);
        view.fill(0);
        view.set(encoded);
        const resultLen = wasmModule.compute_histogram(ptr, bufSize);
        const resultBytes = new Uint8Array(memory.buffer, ptr, resultLen);
        const resultStr = new TextDecoder().decode(resultBytes);
        wasmModule.dealloc(ptr, bufSize);
        return JSON.parse(resultStr);
      } catch (_e) {
        // Fall through to JS
      }
    }
    return jsComputeHistogram(values, numBins);
  }

  // -- Filtering and sorting --

  function applyFilters(data) {
    return data.filter((row) => {
      for (const [col, filter] of Object.entries(activeFilters)) {
        const val = row[col];
        const filterVal = filter.value;
        if (filterVal === "" || filterVal == null) continue;

        switch (filter.op) {
          case "eq":
            if (String(val) !== String(filterVal)) return false;
            break;
          case "gt":
            if (Number(val) <= Number(filterVal)) return false;
            break;
          case "lt":
            if (Number(val) >= Number(filterVal)) return false;
            break;
          case "contains":
            if (!String(val).toLowerCase().includes(String(filterVal).toLowerCase()))
              return false;
            break;
        }
      }
      return true;
    });
  }

  function applySort(data) {
    if (!sortColumn) return data;
    const sorted = [...data];
    sorted.sort((a, b) => {
      const va = a[sortColumn];
      const vb = b[sortColumn];
      const na = Number(va);
      const nb = Number(vb);

      let cmp;
      if (!isNaN(na) && !isNaN(nb)) {
        cmp = na - nb;
      } else {
        cmp = String(va).localeCompare(String(vb));
      }
      return sortDirection === "asc" ? cmp : -cmp;
    });
    return sorted;
  }

  function getProcessedRows() {
    return applySort(applyFilters(rows));
  }

  // -- Rendering --
  // Full render is called once on init. After that, updateTable() patches
  // only the table body, row count, sort indicators, and pagination,
  // leaving filter inputs untouched so they keep focus.

  function render() {
    const processed = getProcessedRows();
    const totalPages = Math.max(1, Math.ceil(processed.length / pageSize));
    if (currentPage > totalPages) currentPage = totalPages;

    const start = (currentPage - 1) * pageSize;
    const pageRows = processed.slice(start, start + pageSize);

    root.innerHTML = `
      <div class="ke-container">
        <div class="ke-header">
          <h3 class="ke-title">${escapeHtml(title)}</h3>
          <span class="ke-badge" id="ke-wasm-badge">JS</span>
          <span class="ke-row-count" id="ke-row-count">${processed.length} of ${rows.length} rows</span>
        </div>

        <div class="ke-toolbar">
          <label class="ke-label">Analyze column:</label>
          <select id="ke-col-select" class="ke-select">
            <option value="">Select a column</option>
            ${columns.map((c) => `<option value="${escapeHtml(c)}" ${c === selectedColumn ? "selected" : ""}>${escapeHtml(c)}</option>`).join("")}
          </select>
        </div>

        <div id="ke-stats-panel" class="ke-stats-panel"></div>
        <div id="ke-histogram" class="ke-histogram"></div>

        <div class="ke-filter-bar" id="ke-filter-bar">
          ${buildFilterBar()}
        </div>

        <div class="ke-table-wrap">
          <table class="ke-table">
            <thead>
              <tr id="ke-thead-row">
                ${columns.map((c) => `<th class="ke-th" data-col="${escapeHtml(c)}">${escapeHtml(c)} ${sortIndicator(c)}</th>`).join("")}
              </tr>
            </thead>
            <tbody id="ke-tbody">
              ${renderRows(pageRows)}
            </tbody>
          </table>
        </div>

        <div class="ke-pagination" id="ke-pagination">
          <button id="ke-prev" class="ke-btn" ${currentPage <= 1 ? "disabled" : ""}>Prev</button>
          <span class="ke-page-info">Page ${currentPage} of ${totalPages}</span>
          <button id="ke-next" class="ke-btn" ${currentPage >= totalPages ? "disabled" : ""}>Next</button>
        </div>
      </div>
    `;

    attachEventListeners();
    if (selectedColumn) {
      renderAnalysis(selectedColumn);
    }
    updateStatusBadge(wasmModule !== null);
  }

  // Partial update: only patches table body, row count, headers, pagination.
  // Filter inputs are NOT touched, so they keep focus.
  function updateTable() {
    const processed = getProcessedRows();
    const totalPages = Math.max(1, Math.ceil(processed.length / pageSize));
    if (currentPage > totalPages) currentPage = totalPages;

    const start = (currentPage - 1) * pageSize;
    const pageRows = processed.slice(start, start + pageSize);

    // Update row count
    const rowCount = root.querySelector("#ke-row-count");
    if (rowCount) rowCount.textContent = `${processed.length} of ${rows.length} rows`;

    // Update sort indicators in headers
    const theadRow = root.querySelector("#ke-thead-row");
    if (theadRow) {
      theadRow.innerHTML = columns.map((c) =>
        `<th class="ke-th" data-col="${escapeHtml(c)}">${escapeHtml(c)} ${sortIndicator(c)}</th>`
      ).join("");
      // Re-attach header click listeners
      theadRow.querySelectorAll(".ke-th").forEach((th) => {
        th.addEventListener("click", () => {
          const col = th.dataset.col;
          if (sortColumn === col) {
            sortDirection = sortDirection === "asc" ? "desc" : "asc";
          } else {
            sortColumn = col;
            sortDirection = "asc";
          }
          ctx.pushEvent("sort_applied", { column: sortColumn, direction: sortDirection });
          updateTable();
        });
      });
    }

    // Update table body
    const tbody = root.querySelector("#ke-tbody");
    if (tbody) tbody.innerHTML = renderRows(pageRows);

    // Update pagination
    const pagination = root.querySelector("#ke-pagination");
    if (pagination) {
      pagination.innerHTML = `
        <button id="ke-prev" class="ke-btn" ${currentPage <= 1 ? "disabled" : ""}>Prev</button>
        <span class="ke-page-info">Page ${currentPage} of ${totalPages}</span>
        <button id="ke-next" class="ke-btn" ${currentPage >= totalPages ? "disabled" : ""}>Next</button>
      `;
      attachPaginationListeners();
    }

    // Update analysis if a column is selected
    if (selectedColumn) renderAnalysis(selectedColumn);
  }

  function renderRows(pageRows) {
    if (pageRows.length === 0) {
      return `<tr><td colspan="${columns.length}" class="ke-empty">No matching rows</td></tr>`;
    }
    return pageRows.map((row) =>
      `<tr>${columns.map((c) => `<td class="ke-td">${escapeHtml(String(row[c] ?? ""))}</td>`).join("")}</tr>`
    ).join("");
  }

  function buildFilterBar() {
    return columns
      .map((col) => {
        const filter = activeFilters[col] || { op: "contains", value: "" };
        return `
        <div class="ke-filter-group">
          <label class="ke-filter-label">${escapeHtml(col)}</label>
          <select class="ke-filter-op" data-col="${escapeHtml(col)}">
            <option value="contains" ${filter.op === "contains" ? "selected" : ""}>contains</option>
            <option value="eq" ${filter.op === "eq" ? "selected" : ""}>=</option>
            <option value="gt" ${filter.op === "gt" ? "selected" : ""}>&gt;</option>
            <option value="lt" ${filter.op === "lt" ? "selected" : ""}>&lt;</option>
          </select>
          <input class="ke-filter-input" data-col="${escapeHtml(col)}" type="text"
                 placeholder="filter..." value="${escapeHtml(filter.value || "")}" />
        </div>
      `;
      })
      .join("");
  }

  function sortIndicator(col) {
    if (sortColumn !== col) return "";
    return sortDirection === "asc" ? " &#9650;" : " &#9660;";
  }

  function renderAnalysis(col) {
    const values = rows
      .map((r) => Number(r[col]))
      .filter((v) => !isNaN(v));

    const statsPanel = root.querySelector("#ke-stats-panel");
    const histPanel = root.querySelector("#ke-histogram");

    if (values.length === 0) {
      statsPanel.innerHTML = `<p class="ke-note">Column "${escapeHtml(col)}" has no numeric values to analyze.</p>`;
      histPanel.innerHTML = "";
      return;
    }

    const stats = computeStats(values);
    statsPanel.innerHTML = `
      <div class="ke-stats-grid">
        <div class="ke-stat"><span class="ke-stat-label">Count</span><span class="ke-stat-value">${stats.count}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">Min</span><span class="ke-stat-value">${fmtNum(stats.min)}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">Max</span><span class="ke-stat-value">${fmtNum(stats.max)}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">Mean</span><span class="ke-stat-value">${fmtNum(stats.mean)}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">Median</span><span class="ke-stat-value">${fmtNum(stats.median)}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">Std Dev</span><span class="ke-stat-value">${fmtNum(stats.std_dev)}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">P25</span><span class="ke-stat-value">${fmtNum(stats.p25)}</span></div>
        <div class="ke-stat"><span class="ke-stat-label">P75</span><span class="ke-stat-value">${fmtNum(stats.p75)}</span></div>
      </div>
    `;

    const hist = computeHistogram(values, 20);
    if (hist.counts && hist.counts.length > 0) {
      const maxCount = Math.max(...hist.counts);
      const barWidth = 100 / hist.counts.length;

      histPanel.innerHTML = `
        <div class="ke-hist-title">Histogram: ${escapeHtml(col)}</div>
        <div class="ke-hist-chart">
          ${hist.counts
            .map((count, i) => {
              const height = maxCount > 0 ? (count / maxCount) * 100 : 0;
              const label = fmtNum(hist.bins[i]) + " - " + fmtNum(hist.bins[i + 1]);
              return `<div class="ke-hist-bar-wrap" style="width:${barWidth}%" title="${label}: ${count}">
                <div class="ke-hist-bar" style="height:${height}%"></div>
                <div class="ke-hist-count">${count}</div>
              </div>`;
            })
            .join("")}
        </div>
        <div class="ke-hist-axis">
          <span>${fmtNum(hist.min)}</span>
          <span>${fmtNum(hist.max)}</span>
        </div>
      `;
    } else {
      histPanel.innerHTML = "";
    }
  }

  // -- Event listeners --

  function attachPaginationListeners() {
    const prevBtn = root.querySelector("#ke-prev");
    const nextBtn = root.querySelector("#ke-next");
    if (prevBtn) {
      prevBtn.addEventListener("click", () => {
        if (currentPage > 1) { currentPage--; updateTable(); }
      });
    }
    if (nextBtn) {
      nextBtn.addEventListener("click", () => {
        const processed = getProcessedRows();
        const totalPages = Math.ceil(processed.length / pageSize);
        if (currentPage < totalPages) { currentPage++; updateTable(); }
      });
    }
  }

  function attachEventListeners() {
    const colSelect = root.querySelector("#ke-col-select");
    colSelect.addEventListener("change", () => {
      selectedColumn = colSelect.value || null;
      ctx.pushEvent("column_selected", { column: selectedColumn });
      if (selectedColumn) {
        renderAnalysis(selectedColumn);
      } else {
        root.querySelector("#ke-stats-panel").innerHTML = "";
        root.querySelector("#ke-histogram").innerHTML = "";
      }
    });

    root.querySelectorAll(".ke-th").forEach((th) => {
      th.addEventListener("click", () => {
        const col = th.dataset.col;
        if (sortColumn === col) {
          sortDirection = sortDirection === "asc" ? "desc" : "asc";
        } else {
          sortColumn = col;
          sortDirection = "asc";
        }
        ctx.pushEvent("sort_applied", { column: sortColumn, direction: sortDirection });
        updateTable();
      });
    });

    root.querySelectorAll(".ke-filter-input").forEach((input) => {
      let timeout;
      input.addEventListener("input", () => {
        const col = input.dataset.col;
        pendingFilterCols.add(col);
        clearTimeout(timeout);
        timeout = setTimeout(() => {
          pendingFilterCols.delete(col);
          const opSelect = root.querySelector(`.ke-filter-op[data-col="${col}"]`);
          const op = opSelect ? opSelect.value : "contains";
          const value = input.value;

          if (value === "") {
            delete activeFilters[col];
          } else {
            activeFilters[col] = { op, value };
          }

          ctx.pushEvent("filter_applied", { column: col, op, value });
          currentPage = 1;
          updateTable();
        }, 300);
      });
    });

    root.querySelectorAll(".ke-filter-op").forEach((select) => {
      select.addEventListener("change", () => {
        const col = select.dataset.col;
        const input = root.querySelector(`.ke-filter-input[data-col="${col}"]`);
        if (input && input.value) {
          activeFilters[col] = { op: select.value, value: input.value };
          ctx.pushEvent("filter_applied", { column: col, op: select.value, value: input.value });
          currentPage = 1;
          updateTable();
        }
      });
    });

    attachPaginationListeners();
  }

  // -- Multi-user sync via Kino.JS.Live events --

  ctx.handleEvent("sync_filters", (data) => {
    activeFilters = JSON.parse(data.filters);
    currentPage = 1;
    // Update filter inputs in-place. Skip columns where the local user
    // is mid-typing (debounce pending) to avoid clobbering their input.
    root.querySelectorAll(".ke-filter-input").forEach((input) => {
      const col = input.dataset.col;
      if (pendingFilterCols.has(col)) return;
      const filter = activeFilters[col];
      input.value = filter ? filter.value : "";
    });
    root.querySelectorAll(".ke-filter-op").forEach((select) => {
      const col = select.dataset.col;
      if (pendingFilterCols.has(col)) return;
      const filter = activeFilters[col];
      select.value = filter ? filter.op : "contains";
    });
    updateTable();
  });

  ctx.handleEvent("sync_column_selected", (data) => {
    selectedColumn = data.column;
    const colSelect = root.querySelector("#ke-col-select");
    if (colSelect) colSelect.value = selectedColumn || "";
    if (selectedColumn) {
      renderAnalysis(selectedColumn);
    } else {
      root.querySelector("#ke-stats-panel").innerHTML = "";
      root.querySelector("#ke-histogram").innerHTML = "";
    }
  });

  ctx.handleEvent("sync_sort", (data) => {
    sortColumn = data.column;
    sortDirection = data.direction;
    updateTable();
  });

  // -- Utilities --

  function updateStatusBadge(isWasm) {
    const badge = root.querySelector("#ke-wasm-badge");
    if (!badge) return;
    if (isWasm) {
      badge.textContent = "WASM";
      badge.classList.add("ke-badge-wasm");
      badge.classList.remove("ke-badge-js");
    } else {
      badge.textContent = "JS";
      badge.classList.add("ke-badge-js");
      badge.classList.remove("ke-badge-wasm");
    }
  }

  function escapeHtml(str) {
    const div = document.createElement("div");
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
  }

  function fmtNum(n) {
    if (n == null) return "N/A";
    const num = Number(n);
    if (isNaN(num)) return String(n);
    if (Number.isInteger(num)) return num.toLocaleString();
    return num.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 4 });
  }

  // -- Bootstrap --

  render();
  tryLoadWasm();
}
