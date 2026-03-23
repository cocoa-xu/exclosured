// Private Analytics - Client-side application
// All data processing happens in the browser via DuckDB-WASM.
// The server only relays encrypted (opaque) blobs between participants.
// Computation (table rendering, PII masking, histogram, profiling) is
// delegated to the Rust WASM module (rust_hook).

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// === Utility functions (DOM-centric, must stay in JS) ====================

function escapeHTML(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function showToast(message, type) {
  const toast = document.getElementById("status-toast")
  if (!toast) return
  toast.textContent = message
  toast.className = "status-toast visible" + (type ? " " + type : "")
  clearTimeout(toast._timer)
  toast._timer = setTimeout(() => { toast.className = "status-toast" }, 3000)
}

function copyToClipboard(text) {
  navigator.clipboard.writeText(text).then(() => {
    showToast("Copied to clipboard", "success")
  }).catch(() => {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.select()
    document.execCommand("copy")
    document.body.removeChild(ta)
    showToast("Copied to clipboard", "success")
  })
}

// === Table rendering (Rust HTML + JS drag listeners)

function renderTable(tableEl, emptyEl, columns, rows, rustHook, onReorder) {
  if (!tableEl) return
  if (!columns || columns.length === 0 || !rows || rows.length === 0) {
    tableEl.style.display = "none"
    if (emptyEl) { emptyEl.style.display = "block"; emptyEl.textContent = "Query returned no results." }
    return
  }

  // Rust generates the full <thead> + <tbody> HTML. We pass page=1 and
  // page_size=rows.length because JS already sliced rows to the current page.
  if (rustHook) {
    tableEl.innerHTML = rustHook.render_table_html(
      JSON.stringify(columns), JSON.stringify(rows), 1, rows.length
    )
  } else {
    let html = "<thead><tr><th class=\"row-num\">#</th>"
    for (const col of columns) html += `<th>${escapeHTML(col)}</th>`
    html += "</tr></thead><tbody>"
    for (let r = 0; r < rows.length; r++) {
      const row = rows[r]
      html += `<tr><td class="row-num">${r + 1}</td>`
      for (const col of columns) {
        const raw = row[col] !== undefined ? row[col] : null
        html += `<td>${escapeHTML(raw != null ? String(raw) : "")}</td>`
      }
      html += "</tr>"
    }
    html += "</tbody>"
    tableEl.innerHTML = html
  }

  tableEl.style.display = "table"
  if (emptyEl) emptyEl.style.display = "none"

  // Attach drag-to-reorder listeners and data-row-idx attributes.
  if (onReorder) {
    let dragIdx = null
    const ths = tableEl.querySelectorAll("thead th")
    ths.forEach((th, i) => {
      if (i === 0) return
      const colIdx = i - 1
      th.setAttribute("draggable", "true")
      th.dataset.colIdx = colIdx
      th.addEventListener("dragstart", (e) => {
        dragIdx = colIdx; th.classList.add("dragging"); e.dataTransfer.effectAllowed = "move"
      })
      th.addEventListener("dragend", () => { th.classList.remove("dragging"); dragIdx = null })
      th.addEventListener("dragover", (e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; th.classList.add("drag-over") })
      th.addEventListener("dragleave", () => { th.classList.remove("drag-over") })
      th.addEventListener("drop", (e) => {
        e.preventDefault(); th.classList.remove("drag-over")
        if (dragIdx !== null && dragIdx !== colIdx) onReorder(dragIdx, colIdx)
      })
    })
    tableEl.querySelectorAll("tbody tr").forEach((tr, idx) => { tr.dataset.rowIdx = idx })
  }
}

// === LiveView Hook

const Hooks = {}

Hooks.RoomHook = {
  async mounted() {
    this.roomId = this.el.dataset.roomId
    this._db = null
    this._conn = null
    this._pageSize = 50
    this._rustHook = null
    this._wasmMod = null

    // Register event handlers before async work
    this.handleEvent("init_state", () => {
      const hash = window.location.hash
      if (hash && hash.length > 1) {
        const params = new URLSearchParams(hash.substring(1))
        const token = params.get("token")
        if (token) this.pushEvent("join_room", {token_hash: token})
      } else {
        this._viewerToken = this._generateToken()
        this._editorToken = this._generateToken()
        this.pushEvent("create_room", { viewer_hash: this._viewerToken, editor_hash: this._editorToken })
        const uploadArea = document.getElementById("data-load-area")
        if (uploadArea) uploadArea.style.display = "block"
      }
    })
    this.handleEvent("execute_query", (d) => this._executeQuery(d.sql))
    this.handleEvent("execute_remote_query", (d) => {
      try { const p = JSON.parse(d.sql); if (p.type === "page_change") { this._changePage(p.page); return } } catch (_) {}
      this._executeQuery(d.sql)
    })
    this.handleEvent("render_view", (d) => {
      try {
        const parsed = typeof d.data === "string" ? JSON.parse(d.data) : d.data
        if (parsed.columns && parsed.rows) {
          this._resultColumns = parsed.columns; this._resultRows = parsed.rows
          this._currentPage = 1; this._queryElapsed = 0; this._renderCurrentPage()
        }
      } catch (e) { console.error("Failed to render view:", e) }
    })
    this.handleEvent("render_schema", (d) => {
      try { this._renderSchema(typeof d.schema === "string" ? JSON.parse(d.schema) : d.schema) }
      catch (e) { console.error("Failed to render schema:", e) }
    })
    this.handleEvent("change_page", (d) => this._changePage(d.page))
    this.handleEvent("set_theme", (d) => document.documentElement.setAttribute("data-theme", d.theme))
    this.handleEvent("pii_config_update", (d) => {
      const cols = d.masked_columns || []
      showToast(cols.length > 0 ? `Owner updated PII masking: ${cols.length} columns` : "Owner removed PII masking", "")
    })
    // Live SQL sync: another user changed the query text
    this.handleEvent("sync_sql", (d) => {
      if (this._rustSqlHook) {
        this._rustSqlHook.on_event("set_sql", d.sql)
      } else {
        const editor = document.getElementById("sql-editor")
        if (editor) editor.value = d.sql
      }
    })

    this._remoteCursors = []
    this.handleEvent("cursor_update", (d) => { this._remoteCursors = d.cursors || []; this._renderCursors() })

    this._setupSQLEditor()
    this._setupFileUpload()
    this._setupCopyButtons()
    this._setupNameInput()
    this._setupRowHover()
    this._setupHistogram()
    this._setupPiiSection()
    window.__room_hook = this

    // Load crypto WASM module
    try {
      const wasmMod = await import("/wasm/private_analytics_wasm/private_analytics_wasm.js")
      await wasmMod.default("/wasm/private_analytics_wasm/private_analytics_wasm_bg.wasm")
      this._wasmMod = wasmMod
    } catch (e) { console.error("Crypto WASM load failed:", e); this._wasmMod = null }

    this.pushEvent("wasm_ready", {})
    this._duckdbReady = this._initDuckDB()
  },

  updated() {
    if (!this._sqlEditorReady && document.getElementById("sql-editor")) { this._setupSQLEditor(); this._sqlEditorReady = true }
    if (!this._fileUploadReady && document.getElementById("drop-zone")) { this._setupFileUpload(); this._fileUploadReady = true }
    if (!this._copyReady && document.querySelectorAll("[data-copy]").length > 0) { this._setupCopyButtons(); this._copyReady = true }
    if (!this._hoverReady && document.getElementById("results-wrapper")) { this._setupRowHover(); this._hoverReady = true }
    if (!this._nameReady && document.getElementById("display-name-input")) { this._setupNameInput(); this._nameReady = true }
    if (!this._piiReady && document.getElementById("pii-section")) { this._setupPiiSection(); this._piiReady = true }
    if (!this._histogramReady && document.getElementById("histogram-column")) { this._setupHistogram(); this._histogramReady = true }
  },

  _generateToken() {
    const bytes = new Uint8Array(24)
    crypto.getRandomValues(bytes)
    return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
  },

  // === SQL Editor (delegates to Rust SqlEditorHook)

  async _setupSQLEditor() {
    const container = document.getElementById("sql-editor-wrapper")
    if (!container) return
    try {
      const mod = await import(/* webpackIgnore: true */ "/wasm/rust_hook/rust_hook.js")
      await mod.default("/wasm/rust_hook/rust_hook_bg.wasm")
      this._rustHook = mod
      const pushEventFn = (event, payloadStr) => {
        try { this.pushEvent(event, JSON.parse(payloadStr)) }
        catch (_) { this.pushEvent(event, {value: payloadStr}) }
      }
      this._rustSqlHook = new mod.SqlEditorHook(container, pushEventFn)
      this._rustSqlHook.mounted()
      console.log("Rust WASM module loaded")
    } catch (e) {
      console.warn("Rust WASM hook failed, falling back to JS:", e)
      this._rustHook = null
      this._setupSQLEditorJS()
    }
  },

  _setupSQLEditorJS() {
    const editor = document.getElementById("sql-editor")
    const display = document.getElementById("sql-display")
    if (!editor || !display) return
    const sync = () => { display.innerHTML = escapeHTML(editor.value) + "\n"; display.scrollTop = editor.scrollTop; display.scrollLeft = editor.scrollLeft }
    sync()
    editor.addEventListener("input", () => { sync(); this.pushEvent("update_sql", {value: editor.value}) })
    editor.addEventListener("scroll", () => { display.scrollTop = editor.scrollTop; display.scrollLeft = editor.scrollLeft })
    editor.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); this.pushEvent("submit_query", {sql: editor.value}) }
    })
  },

  // === File upload (drag-and-drop + file input, must stay in JS)

  _setupFileUpload() {
    const dropZone = document.getElementById("drop-zone")
    const fileInput = document.getElementById("csv-file-input")
    if (!dropZone || !fileInput) return
    dropZone.addEventListener("click", () => fileInput.click())
    dropZone.addEventListener("dragover", (e) => { e.preventDefault(); dropZone.style.borderColor = "var(--accent)" })
    dropZone.addEventListener("dragleave", () => { dropZone.style.borderColor = "" })
    dropZone.addEventListener("drop", (e) => {
      e.preventDefault(); dropZone.style.borderColor = ""
      if (e.dataTransfer.files.length > 0) this._loadCSV(e.dataTransfer.files[0])
    })
    fileInput.addEventListener("change", () => { if (fileInput.files.length > 0) this._loadCSV(fileInput.files[0]) })
  },

  _setupCopyButtons() {
    document.addEventListener("click", (e) => {
      if (e.target.id === "copy-view-url") { const i = document.getElementById("share-view-url"); if (i) copyToClipboard(i.value) }
      else if (e.target.id === "copy-edit-url") { const i = document.getElementById("share-edit-url"); if (i) copyToClipboard(i.value) }
    })
    this._updateShareURLs()
    new MutationObserver(() => this._updateShareURLs()).observe(this.el, {childList: true, subtree: true})
  },

  _updateShareURLs() {
    const viewInput = document.getElementById("share-view-url")
    const editInput = document.getElementById("share-edit-url")
    if (!viewInput || !editInput || !this._viewerToken || !this._editorToken) return
    const base = window.location.origin + "/room/" + this.roomId
    viewInput.value = base + "#role=viewer&token=" + this._viewerToken
    editInput.value = base + "#role=editor&token=" + this._editorToken
  },

  // === CSV / file loading

  async _loadCSV(file) {
    showToast("Loading " + file.name + "...", "")
    if (!this._db && this._duckdbReady) { showToast("Waiting for DuckDB to initialize...", ""); await this._duckdbReady }

    try {
      if (this._db) {
        const uint8 = new Uint8Array(await file.arrayBuffer())
        await this._db.registerFileBuffer(file.name, uint8)
        const ext = file.name.toLowerCase()
        const createSQL = ext.endsWith(".parquet")
          ? `CREATE OR REPLACE TABLE data AS SELECT * FROM read_parquet('${file.name}')`
          : `CREATE OR REPLACE TABLE data AS SELECT * FROM read_csv_auto('${file.name}')`
        await this._conn.query(createSQL)

        const schemaResult = await this._conn.query("DESCRIBE data")
        const schema = []
        for (let i = 0; i < schemaResult.numRows; i++) {
          schema.push({ name: schemaResult.getChildAt(0).get(i), type: schemaResult.getChildAt(1).get(i) })
        }
        this._schema = schema
        this._renderSchema(schema)
        this.pushEvent("schema_update", {encrypted_schema: JSON.stringify(schema)})
        const area = document.getElementById("data-load-area")
        if (area) area.style.display = "none"
        showToast("Data loaded: " + file.name + " (" + schema.length + " columns)", "success")
        await this._executeQuery("SELECT * FROM data LIMIT 50")
      } else {
        if (file.name.toLowerCase().endsWith(".parquet")) {
          this.pushEvent("query_error", {error: "Parquet files require DuckDB. Please reload the page."}); return
        }
        const reader = new FileReader()
        reader.onload = (e) => this._parseAndLoad(e.target.result, file.name)
        reader.readAsText(file)
      }
    } catch (e) { this.pushEvent("query_error", {error: "Failed to load file: " + e.message}) }
  },

  _parseAndLoad(csvText, filename) {
    const lines = csvText.split("\n").filter(l => l.trim() !== "")
    if (lines.length === 0) { this.pushEvent("query_error", {error: "CSV file is empty."}); return }

    const headers = this._parseCSVLine(lines[0])
    const rows = []
    for (let i = 1; i < lines.length; i++) {
      const parsed = this._parseCSVLine(lines[i])
      if (parsed.length > 0) rows.push(parsed)
    }

    this._tableColumns = headers
    this._tableRows = rows
    this._totalRows = rows.length
    this._pageSize = 50

    const uploadArea = document.getElementById("data-load-area")
    if (uploadArea) uploadArea.style.display = "none"

    const schema = headers.map((h, idx) => {
      let type = "VARCHAR"
      for (let r = 0; r < Math.min(10, rows.length); r++) {
        const val = rows[r][idx]
        if (val === undefined || val === null || val === "") continue
        if (!isNaN(val) && val.includes(".")) { type = "DOUBLE"; break }
        if (!isNaN(val) && !isNaN(parseInt(val))) { type = "BIGINT"; break }
      }
      return {name: h, type}
    })

    this._schema = schema
    this._renderSchema(schema)
    this.pushEvent("schema_update", {encrypted_schema: JSON.stringify(schema)})
    this._executeLocalQuery("SELECT * FROM data LIMIT 50")
    showToast("Loaded " + filename + " (" + rows.length + " rows)", "success")
  },

  _parseCSVLine(line) {
    const result = []
    let current = ""
    let inQuotes = false
    for (let i = 0; i < line.length; i++) {
      const ch = line[i]
      if (inQuotes) {
        if (ch === '"') {
          if (i + 1 < line.length && line[i + 1] === '"') { current += '"'; i++ }
          else inQuotes = false
        } else current += ch
      } else {
        if (ch === '"') inQuotes = true
        else if (ch === ',') { result.push(current.trim()); current = "" }
        else current += ch
      }
    }
    result.push(current.trim())
    return result
  },

  // === DuckDB initialization (must stay in JS)

  async _initDuckDB() {
    const status = document.getElementById("query-status")
    const loadBtn = document.getElementById("btn-load-url")
    try {
      showToast("Loading DuckDB engine...", "")
      if (status) status.textContent = "Downloading DuckDB engine..."
      if (loadBtn) { loadBtn.disabled = true; loadBtn.textContent = "Loading DuckDB..." }

      const duckdb = await import(/* webpackIgnore: true */ "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/+esm")
      if (status) status.textContent = "Initializing DuckDB..."
      const bundles = duckdb.getJsDelivrBundles()
      const bundle = await duckdb.selectBundle(bundles)
      const logger = new duckdb.ConsoleLogger()
      const worker = await duckdb.createWorker(bundle.mainWorker)
      const db = new duckdb.AsyncDuckDB(logger, worker)
      await db.instantiate(bundle.mainModule)

      this._db = db
      this._conn = await db.connect()
      window.__duckdb_conn = this._conn
      if (status) status.textContent = "DuckDB ready"
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load" }
      showToast("DuckDB ready", "success")
    } catch (e) {
      console.error("DuckDB init failed:", e)
      if (status) status.textContent = "DuckDB failed to load"
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load" }
      showToast("DuckDB failed to load: " + e.message, "error")
      this._db = null; this._conn = null
    }
  },

  // === Query execution (DuckDB + Arrow extraction, must stay in JS)

  async _executeQuery(sql) {
    if (!this._conn && this._duckdbReady) { showToast("Waiting for DuckDB...", ""); await this._duckdbReady }
    if (!this._conn) { this.pushEvent("query_error", {error: "DuckDB not loaded. Please reload the page."}); return }

    try {
      const start = performance.now()
      const result = await this._conn.query(sql)
      const elapsed = Math.round(performance.now() - start)

      const columns = result.schema.fields.map(f => f.name)
      const allRows = []
      for (let i = 0; i < result.numRows; i++) {
        const row = {}
        for (let c = 0; c < columns.length; c++) {
          let val = result.getChildAt(c).get(i)
          if (typeof val === "bigint") {
            val = (val >= Number.MIN_SAFE_INTEGER && val <= Number.MAX_SAFE_INTEGER) ? Number(val) : val.toString()
          }
          row[columns[c]] = val
        }
        allRows.push(row)
      }

      this._resultColumns = columns
      this._resultRows = allRows
      this._localColumnOrder = null
      this._currentPage = 1
      this._queryElapsed = elapsed

      this._renderCurrentPage()
      this._broadcastMaskedResults(columns, allRows)

      if (this._rustSqlHook) {
        const editor = document.getElementById("sql-editor")
        if (editor) { editor.value = sql; this._rustSqlHook.highlight() }
      }
    } catch (e) { this.pushEvent("query_error", {error: "Query error: " + e.message}) }
  },

  // === Page rendering (Rust generates table HTML)

  _renderCurrentPage() {
    if (!this._resultColumns || !this._resultRows) return
    const rows = this._resultRows
    const columns = this._localColumnOrder || this._resultColumns
    const pageSize = this._pageSize || 50
    const page = this._currentPage || 1
    const totalRows = rows.length
    const totalPages = Math.max(1, Math.ceil(totalRows / pageSize))
    const startIdx = (page - 1) * pageSize
    let pageRows = rows.slice(startIdx, startIdx + pageSize)

    // Apply self-masking using Rust mask_value
    const selfMask = document.getElementById("pii-mask-self")
    const maskedCols = this._piiMaskedColumns || []
    if (selfMask && selfMask.checked && maskedCols.length > 0) {
      pageRows = pageRows.map(row => {
        const masked = {...row}
        for (const col of maskedCols) { if (masked[col] != null) masked[col] = this._maskValue(String(masked[col])) }
        return masked
      })
    }

    const table = document.getElementById("results-table")
    const empty = document.getElementById("results-empty")
    renderTable(table, empty, columns, pageRows, this._rustHook, (fromIdx, toIdx) => {
      const order = [...columns]
      const [moved] = order.splice(fromIdx, 1)
      order.splice(toIdx, 0, moved)
      this._localColumnOrder = order
      this._renderCurrentPage()
    })

    this._renderCursors()

    const status = document.getElementById("query-status")
    if (status) status.textContent = `${totalRows} total rows, ${this._queryElapsed || 0}ms`

    const histSelect = document.getElementById("histogram-column")
    if (histSelect && this._resultColumns) {
      histSelect.innerHTML = '<option value="">Select a column</option>' +
        this._resultColumns.map(c => `<option value="${escapeHTML(c)}">${escapeHTML(c)}</option>`).join("")
    }

    const piiIndicator = document.getElementById("pii-indicator")
    if (piiIndicator) {
      if (maskedCols.length > 0) { piiIndicator.textContent = `${maskedCols.length} columns masked`; piiIndicator.style.display = "inline" }
      else piiIndicator.style.display = "none"
    }
    this._renderPiiColumns()
    this._renderPagination(page, totalPages, totalRows, pageSize)
  },

  _renderPagination(page, totalPages, totalRows, pageSize) {
    let container = document.getElementById("local-pagination")
    if (!container) {
      const wrapper = document.getElementById("results-wrapper")
      if (!wrapper) return
      container = document.createElement("div")
      container.id = "local-pagination"
      container.className = "local-pagination"
      wrapper.parentNode.insertBefore(container, wrapper.nextSibling)
    }
    container.innerHTML = `
      <div class="pagination-row">
        <button class="btn btn-sm" id="pg-prev" ${page <= 1 ? "disabled" : ""}>Prev</button>
        <span class="pagination-info">Page ${page} of ${totalPages} (${totalRows} rows)</span>
        <button class="btn btn-sm" id="pg-next" ${page >= totalPages ? "disabled" : ""}>Next</button>
        <select id="pg-size" class="page-size-select">
          ${[10, 50, 100, 200].map(s => `<option value="${s}" ${s === pageSize ? "selected" : ""}>${s} / page</option>`).join("")}
        </select>
        ${this._localColumnOrder ? '<button class="btn btn-sm" id="pg-reset-cols" title="Reset column order">Reset columns</button>' : ''}
      </div>`
    document.getElementById("pg-prev").onclick = () => { if (this._currentPage > 1) { this._currentPage--; this._renderCurrentPage() } }
    document.getElementById("pg-next").onclick = () => {
      if (this._currentPage < Math.ceil(this._resultRows.length / (this._pageSize || 50))) { this._currentPage++; this._renderCurrentPage() }
    }
    document.getElementById("pg-size").onchange = (e) => { this._pageSize = parseInt(e.target.value); this._currentPage = 1; this._renderCurrentPage() }
    const resetBtn = document.getElementById("pg-reset-cols")
    if (resetBtn) resetBtn.onclick = () => { this._localColumnOrder = null; this._renderCurrentPage() }
  },

  // === Simple SQL engine for CSV fallback (no DuckDB)

  _runSimpleSQL(sql) {
    const normalized = sql.replace(/\s+/g, " ").trim()
    const upperSQL = normalized.toUpperCase()
    if (!upperSQL.startsWith("SELECT")) throw new Error("Only SELECT queries are supported in this demo.")

    let columns = this._tableColumns
    let rows = [...this._tableRows]
    let limit = rows.length
    const limitMatch = upperSQL.match(/LIMIT\s+(\d+)/)
    if (limitMatch) limit = parseInt(limitMatch[1])
    let offset = 0
    const offsetMatch = upperSQL.match(/OFFSET\s+(\d+)/)
    if (offsetMatch) offset = parseInt(offsetMatch[1])

    const fromIdx = upperSQL.indexOf(" FROM ")
    const selectPart = fromIdx > 0 ? normalized.substring(7, fromIdx).trim() : normalized.substring(7).trim()
    let selectedCols = columns
    let selectedIndices = columns.map((_, i) => i)

    if (selectPart !== "*") {
      const colNames = selectPart.split(",").map(c => c.trim())
      selectedIndices = []; selectedCols = []
      for (const cn of colNames) {
        const asMatch = cn.match(/^(.+?)\s+AS\s+(.+)$/i)
        const colName = asMatch ? asMatch[1].trim() : cn
        const alias = asMatch ? asMatch[2].trim() : cn
        const idx = columns.findIndex(c => c.toLowerCase() === colName.toLowerCase())
        if (idx >= 0) { selectedIndices.push(idx); selectedCols.push(alias) }
        else if (colName.toUpperCase() === "COUNT(*)") return { columns: [alias], rows: [[rows.length]], totalRows: 1 }
      }
    }

    const whereIdx = upperSQL.indexOf(" WHERE ")
    if (whereIdx > 0) {
      let endIdx = upperSQL.length
      for (const kw of [" ORDER ", " LIMIT ", " OFFSET ", " GROUP "]) { const ki = upperSQL.indexOf(kw, whereIdx + 7); if (ki > 0 && ki < endIdx) endIdx = ki }
      const whereClause = normalized.substring(whereIdx + 7, endIdx).trim()
      rows = this._filterRows(rows, columns, whereClause)
    }

    const orderIdx = upperSQL.indexOf(" ORDER BY ")
    if (orderIdx > 0) {
      let endIdx = upperSQL.length
      for (const kw of [" LIMIT ", " OFFSET "]) { const ki = upperSQL.indexOf(kw, orderIdx + 10); if (ki > 0 && ki < endIdx) endIdx = ki }
      rows = this._sortRows(rows, columns, normalized.substring(orderIdx + 10, endIdx).trim())
    }

    const totalRows = rows.length
    rows = rows.slice(offset, offset + limit)
    return { columns: selectedCols, rows: rows.map(row => selectedIndices.map(i => row[i] !== undefined ? row[i] : "")), totalRows }
  },

  _filterRows(rows, columns, whereClause) {
    const likeMatch = whereClause.match(/^(\w+)\s+LIKE\s+'(.+)'$/i)
    if (likeMatch) {
      const colIdx = columns.findIndex(c => c.toLowerCase() === likeMatch[1].toLowerCase())
      if (colIdx < 0) return rows
      const re = new RegExp("^" + likeMatch[2].replace(/%/g, ".*").replace(/_/g, ".") + "$", "i")
      return rows.filter(r => re.test(r[colIdx] || ""))
    }
    const cmpMatch = whereClause.match(/^(\w+)\s*(=|!=|<>|>=|<=|>|<)\s*'?([^']*)'?$/i)
    if (cmpMatch) {
      const colIdx = columns.findIndex(c => c.toLowerCase() === cmpMatch[1].toLowerCase())
      if (colIdx < 0) return rows
      const op = cmpMatch[2], val = cmpMatch[3]
      return rows.filter(r => {
        const cell = r[colIdx] || "", numCell = parseFloat(cell), numVal = parseFloat(val), useNum = !isNaN(numCell) && !isNaN(numVal)
        switch (op) {
          case "=": return useNum ? numCell === numVal : cell === val
          case "!=": case "<>": return useNum ? numCell !== numVal : cell !== val
          case ">": return useNum ? numCell > numVal : cell > val
          case "<": return useNum ? numCell < numVal : cell < val
          case ">=": return useNum ? numCell >= numVal : cell >= val
          case "<=": return useNum ? numCell <= numVal : cell <= val
          default: return true
        }
      })
    }
    return rows
  },

  _sortRows(rows, columns, orderClause) {
    const sortKeys = orderClause.split(",").map(p => {
      const tokens = p.trim().split(/\s+/)
      return { idx: columns.findIndex(c => c.toLowerCase() === tokens[0].toLowerCase()), dir: (tokens[1] || "ASC").toUpperCase() === "DESC" ? -1 : 1 }
    }).filter(k => k.idx >= 0)

    return rows.sort((a, b) => {
      for (const {idx, dir} of sortKeys) {
        const va = a[idx] || "", vb = b[idx] || "", na = parseFloat(va), nb = parseFloat(vb)
        if (!isNaN(na) && !isNaN(nb)) { if (na !== nb) return (na - nb) * dir }
        else { const cmp = va.localeCompare(vb); if (cmp !== 0) return cmp * dir }
      }
      return 0
    })
  },

  _changePage(page) {
    if (!this._tableRows) return
    const pageSize = this._pageSize || 50
    this._executeLocalQuery("SELECT * FROM data LIMIT " + pageSize + " OFFSET " + ((page - 1) * pageSize))
  },

  // === Schema rendering

  _renderSchema(schema) {
    const container = document.getElementById("schema-list")
    if (!container || !schema) return
    let html = `<div class="schema-count">${schema.length} columns</div>`
    for (const col of schema) {
      html += `<div class="schema-col"><span class="schema-col-name">${escapeHTML(col.name)}</span><span class="schema-col-type">${escapeHTML(col.type)}</span></div>`
    }
    container.innerHTML = html
  },

  _setupNameInput() {
    const input = document.getElementById("display-name-input")
    if (!input) return
    let debounce = null
    input.addEventListener("input", () => {
      clearTimeout(debounce)
      debounce = setTimeout(() => { this.pushEvent("set_display_name", {name: input.value.trim() || "Anonymous"}) }, 300)
    })
  },

  // === Row hover and cursor rendering (DOM manipulation, stays in JS)

  _setupRowHover() {
    const wrapper = document.getElementById("results-wrapper")
    if (!wrapper) return
    this._pinnedRow = null
    let lastRow = null

    wrapper.addEventListener("mouseover", (e) => {
      if (this._pinnedRow !== null) return
      const tr = e.target.closest("tbody tr"); if (!tr) return
      const rowIdx = parseInt(tr.dataset.rowIdx); if (isNaN(rowIdx) || rowIdx === lastRow) return
      lastRow = rowIdx
      const page = this._currentPage || 1, pageSize = this._pageSize || 50
      this._myHoverRow = (page - 1) * pageSize + rowIdx
      this._renderCursors()
      this.pushEvent("cursor_hover", {row: this._myHoverRow, page, page_size: pageSize})
    })

    wrapper.addEventListener("mouseleave", () => {
      if (this._pinnedRow !== null) return
      lastRow = null; this._myHoverRow = -1; this._renderCursors()
      this.pushEvent("cursor_hover", {row: -1, page: this._currentPage || 1, page_size: this._pageSize || 50})
    })

    wrapper.addEventListener("click", (e) => {
      const tr = e.target.closest("tbody tr"); if (!tr) return
      if (e.target.closest(".cursor-dot, .cursor-indicators")) return
      const rowIdx = parseInt(tr.dataset.rowIdx); if (isNaN(rowIdx)) return
      const page = this._currentPage || 1, pageSize = this._pageSize || 50
      const absRow = (page - 1) * pageSize + rowIdx
      if (this._pinnedRow === absRow) {
        this._pinnedRow = null; this._myHoverRow = -1; this._renderCursors()
        this.pushEvent("cursor_hover", {row: -1, page, page_size: pageSize})
      } else {
        this._pinnedRow = absRow; this._myHoverRow = absRow; this._renderCursors()
        this.pushEvent("cursor_hover", {row: absRow, page, page_size: pageSize})
      }
    })
  },

  _renderCursors() {
    const table = document.getElementById("results-table")
    if (!table) return
    table.querySelectorAll(".cursor-indicators").forEach(el => el.remove())
    table.querySelectorAll(".has-cursors").forEach(el => el.classList.remove("has-cursors"))
    document.querySelectorAll(".offpage-cursor").forEach(el => el.remove())

    const myPage = this._currentPage || 1, myPageSize = this._pageSize || 50
    const myStart = (myPage - 1) * myPageSize, myEnd = myStart + myPageSize
    const myHover = this._myHoverRow != null ? this._myHoverRow : -1
    const onPage = [], abovePage = [], belowPage = []

    for (const c of (this._remoteCursors || [])) {
      if (c.row == null || c.row < 0) continue
      if (c.row < myStart) abovePage.push(c)
      else if (c.row >= myEnd) belowPage.push(c)
      else onPage.push({...c, localRow: c.row - myStart})
    }
    if (myHover >= myStart && myHover < myEnd) {
      onPage.push({ name: "You", color: "#ffffff", localRow: myHover - myStart, isMe: true })
    }

    const tbody = table.querySelector("tbody")
    if (tbody) {
      const trs = tbody.querySelectorAll("tr")
      const byRow = {}
      for (const c of onPage) { if (!byRow[c.localRow]) byRow[c.localRow] = []; byRow[c.localRow].push(c) }
      for (const [rowIdx, cursors] of Object.entries(byRow)) {
        const tr = trs[parseInt(rowIdx)]; if (!tr) continue
        tr.classList.add("has-cursors")
        const cell = tr.querySelector("td.row-num") || tr.querySelector("td:first-child"); if (!cell) continue
        const container = document.createElement("div")
        container.className = "cursor-indicators"
        container.setAttribute("data-tooltip", cursors.map(c => c.name).join(", "))
        for (const c of cursors) {
          const dot = document.createElement("div")
          dot.className = c.isMe ? "cursor-dot cursor-dot-me" : "cursor-dot"
          if (!c.isMe) dot.style.backgroundColor = c.color
          container.appendChild(dot)
        }
        cell.appendChild(container)
      }
    }

    const wrapper = document.getElementById("results-wrapper")
    if (wrapper && abovePage.length > 0) {
      const banner = document.createElement("div"); banner.className = "offpage-cursor"
      banner.innerHTML = abovePage.map(c => `<span class="offpage-dot" style="background:${c.color}"></span> ${escapeHTML(c.name)} on row ${c.row + 1}`).join(", ")
      wrapper.insertBefore(banner, wrapper.firstChild)
    }
    if (wrapper && belowPage.length > 0) {
      const banner = document.createElement("div"); banner.className = "offpage-cursor"
      banner.innerHTML = belowPage.map(c => `<span class="offpage-dot" style="background:${c.color}"></span> ${escapeHTML(c.name)} on row ${c.row + 1}`).join(", ")
      wrapper.appendChild(banner)
    }
  },

  // === PII section (detection via Rust, UI in JS)

  _setupPiiSection() {
    const section = document.getElementById("pii-section"); if (!section) return
    const selfMask = document.getElementById("pii-mask-self")
    if (selfMask) selfMask.addEventListener("change", () => this._renderCurrentPage())
    const autoBtn = document.getElementById("pii-auto-detect")
    if (autoBtn) autoBtn.addEventListener("click", () => this._autoDetectPii())
    const selectAll = document.getElementById("pii-select-all")
    if (selectAll) selectAll.addEventListener("click", () => { this._piiMaskedColumns = [...(this._resultColumns || [])]; this._renderPiiColumns(); this._onPiiColumnsChanged() })
    const selectNone = document.getElementById("pii-select-none")
    if (selectNone) selectNone.addEventListener("click", () => { this._piiMaskedColumns = []; this._renderPiiColumns(); this._onPiiColumnsChanged() })
  },

  _renderPiiColumns() {
    const container = document.getElementById("pii-column-list")
    if (!container || !this._resultColumns) return
    const masked = this._piiMaskedColumns || []
    const autoDetected = this._piiAutoDetected || []
    container.innerHTML = this._resultColumns.map(col => {
      const cls = ["pii-chip"]
      if (masked.includes(col)) cls.push("selected")
      if (autoDetected.includes(col)) cls.push("auto-detected")
      return `<label class="${cls.join(" ")}" data-col="${escapeHTML(col)}"><span class="pii-chip-dot"></span><span>${escapeHTML(col)}</span><input type="checkbox" ${masked.includes(col) ? "checked" : ""} /></label>`
    }).join("")

    const countEl = container.parentElement.querySelector(".pii-masked-count")
    if (countEl) {
      countEl.textContent = masked.length > 0 ? `${masked.length} of ${this._resultColumns.length} columns will be masked` : ""
    } else if (masked.length > 0) {
      const p = document.createElement("p"); p.className = "pii-masked-count"
      p.textContent = `${masked.length} of ${this._resultColumns.length} columns will be masked`
      container.parentElement.appendChild(p)
    }

    container.querySelectorAll(".pii-chip").forEach(chip => {
      chip.addEventListener("click", (e) => {
        e.preventDefault()
        const col = chip.dataset.col, idx = this._piiMaskedColumns.indexOf(col)
        if (idx >= 0) this._piiMaskedColumns.splice(idx, 1); else this._piiMaskedColumns.push(col)
        this._renderPiiColumns(); this._onPiiColumnsChanged()
      })
    })
  },

  _onPiiColumnsChanged() {
    this._renderCurrentPage()
    this.pushEvent("pii_columns_changed", {columns: this._piiMaskedColumns || []})
    if (this._resultColumns && this._resultRows) this._broadcastMaskedResults(this._resultColumns, this._resultRows)
  },

  // PII auto-detection: delegated to Rust detect_pii_columns()
  _autoDetectPii() {
    if (!this._resultRows || !this._resultColumns) return
    if (this._rustHook) {
      try {
        const dataJson = JSON.stringify({ columns: this._resultColumns, rows: this._resultRows.slice(0, 100) })
        const detected = JSON.parse(this._rustHook.detect_pii_columns(dataJson))
        this._piiAutoDetected = detected; this._piiMaskedColumns = [...detected]
        this._renderPiiColumns(); this._onPiiColumnsChanged()
        showToast(detected.length > 0 ? `Auto-detected ${detected.length} PII column${detected.length > 1 ? "s" : ""}: ${detected.join(", ")}` : "No PII patterns detected in the data", detected.length > 0 ? "success" : "")
        return
      } catch (e) { console.warn("Rust PII detection failed:", e) }
    }
    showToast("PII detection requires the Rust WASM module", "error")
  },

  // === PII masking (delegated to Rust mask_value)

  _broadcastMaskedResults(columns, allRows) {
    const maskedCols = this._piiMaskedColumns || []
    const broadcastData = maskedCols.length > 0
      ? this._applySelectiveMasking(columns, allRows, maskedCols)
      : JSON.stringify({columns, rows: allRows})
    this.pushEvent("query_result", { data: broadcastData, total_rows: allRows.length })
  },

  _applySelectiveMasking(columns, rows, maskedCols) {
    const maskedRows = rows.map(row => {
      const newRow = {...row}
      for (const col of maskedCols) { if (newRow[col] != null) newRow[col] = this._maskValue(String(newRow[col])) }
      return newRow
    })
    return JSON.stringify({columns, rows: maskedRows})
  },

  // Single value masking: delegates to Rust mask_value()
  _maskValue(val) {
    if (val === null || val === undefined || val === "") return val
    if (this._rustHook) { try { return this._rustHook.mask_value(String(val)) } catch (_) {} }
    return "******"  // Fallback: generic mask
  },

  // === Histogram (Rust compute_histogram + draw_histogram)

  _setupHistogram() {
    const select = document.getElementById("histogram-column"); if (!select) return
    select.addEventListener("change", () => {
      const colName = select.value
      if (!colName || !this._resultRows) {
        const canvas = document.getElementById("histogram-canvas"); if (canvas) canvas.style.display = "none"
        const statsEl = document.getElementById("column-stats"); if (statsEl) statsEl.innerHTML = ""
        const statusEl = document.getElementById("analysis-status"); if (statusEl) statusEl.textContent = ""
        return
      }

      const statusEl = document.getElementById("analysis-status")
      if (statusEl) statusEl.textContent = "Analyzing..."

      const values = this._resultRows.map(r => r[colName])
      const isNumericCol = values.some(v => typeof v === "number")

      if (isNumericCol) {
        this._drawHistogram(values.filter(v => typeof v === "number"))
      } else {
        const canvas = document.getElementById("histogram-canvas"); if (canvas) canvas.style.display = "none"
      }

      // Profile column via Rust
      const rustMod = this._rustHook || this._wasmMod
      if (rustMod && rustMod.profile_column) {
        try {
          const profile = JSON.parse(rustMod.profile_column(JSON.stringify(values), isNumericCol ? "numeric" : "text"))
          this._renderProfile(profile, isNumericCol)
        } catch (e) { console.error("Column profiling failed:", e) }
      }

      if (statusEl) statusEl.textContent = ""
    })
  },

  // Histogram: delegates to Rust draw_histogram() for canvas rendering
  _drawHistogram(numValues) {
    const canvas = document.getElementById("histogram-canvas"); if (!canvas) return
    const rustMod = this._rustHook || this._wasmMod
    if (!rustMod || !rustMod.compute_histogram) { canvas.style.display = "none"; return }

    try {
      const histJson = rustMod.compute_histogram(JSON.stringify(numValues), 20)
      if (this._rustHook && this._rustHook.draw_histogram) {
        canvas.style.display = "block"
        const theme = document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark"
        this._rustHook.draw_histogram(canvas, histJson, theme)
      } else {
        canvas.style.display = "none"
      }
    } catch (e) { console.error("Histogram failed:", e); canvas.style.display = "none" }
  },

  // Profile rendering (DOM manipulation, stays in JS)
  // Adapts field names: Rust uses total/nulls/std, original JS used count/null_count/std_dev
  _renderProfile(profile, isNumeric) {
    const statsEl = document.getElementById("column-stats"); if (!statsEl) return
    const count = profile.count !== undefined ? profile.count : profile.total
    const nullCount = profile.null_count !== undefined ? profile.null_count : profile.nulls
    const stdDev = profile.std_dev !== undefined ? profile.std_dev : profile.std

    let html = ""
    if (isNumeric) {
      const entries = [
        ["Count", count], ["Min", profile.min], ["Max", profile.max],
        ["Mean", typeof profile.mean === "number" ? profile.mean.toFixed(4) : profile.mean],
        ["Median", typeof profile.median === "number" ? profile.median.toFixed(4) : profile.median],
        ["Std Dev", typeof stdDev === "number" ? stdDev.toFixed(4) : stdDev],
        ["Nulls", nullCount]
      ]
      html = '<div class="stats-grid">'
      for (const [label, value] of entries) {
        if (value !== undefined && value !== null)
          html += `<div class="stat-item"><span class="stat-label">${escapeHTML(label)}</span><span class="stat-value">${escapeHTML(String(value))}</span></div>`
      }
      html += '</div>'
    } else {
      html = '<div class="stats-grid">'
      if (count !== undefined) html += `<div class="stat-item"><span class="stat-label">Count</span><span class="stat-value">${count}</span></div>`
      if (profile.unique !== undefined) html += `<div class="stat-item"><span class="stat-label">Unique</span><span class="stat-value">${profile.unique}</span></div>`
      if (nullCount !== undefined) html += `<div class="stat-item"><span class="stat-label">Nulls</span><span class="stat-value">${nullCount}</span></div>`
      html += '</div>'
      if (profile.top_values && profile.top_values.length > 0) {
        const total = count || 1
        html += '<div class="top-values"><div class="stat-label" style="margin-bottom:0.3rem;">Top values</div>'
        for (const tv of profile.top_values.slice(0, 10)) {
          const pct = total > 0 ? ((tv.count / total) * 100).toFixed(1) : "0"
          html += `<div class="top-value-row"><span class="top-value-name">${escapeHTML(String(tv.value))}</span><span class="top-value-bar"><span class="top-value-fill" style="width:${pct}%"></span></span><span class="top-value-count">${tv.count} (${pct}%)</span></div>`
        }
        html += '</div>'
      }
    }
    statsEl.innerHTML = html
  },

  destroyed() { window.__room_hook = null }
}

// === Connect LiveSocket

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, { params: {_csrf_token: csrfToken}, hooks: Hooks })
liveSocket.connect()

document.addEventListener("click", (e) => {
  const popover = document.querySelector(".share-popover"); if (!popover) return
  const container = document.querySelector(".share-popover-container")
  if (container && !container.contains(e.target) && window.__room_hook) window.__room_hook.pushEvent("toggle_share", {})
})

window.liveSocket = liveSocket

window.togglePiiSection = function() {
  const body = document.getElementById("pii-config"), icon = document.getElementById("pii-collapse-icon")
  if (!body) return; body.classList.toggle("collapsed")
  if (icon) icon.innerHTML = body.classList.contains("collapsed") ? "&#9654;" : "&#9660;"
}

window.toggleSchema = function() {
  const container = document.getElementById("schema-container"), icon = document.getElementById("schema-collapse-icon")
  if (!container) return; container.classList.toggle("collapsed")
  if (icon) icon.innerHTML = container.classList.contains("collapsed") ? "&#9654;" : "&#9660;"
}

window.handleSampleData = function(event) {
  const fileTab = document.querySelector('.load-tab[data-tab="file"]');
  const urlTab = document.querySelector('.load-tab[data-tab="url"]');
  const isUrlMode = urlTab && urlTab.classList.contains("active");

  if (isUrlMode) {
    // Fill the URL input with the sample data URL
    event.preventDefault();
    const urlInput = document.getElementById("data-url-input");
    if (urlInput) {
      urlInput.value = window.location.origin + "/sample_data.csv";
    }
    return false;
  } else {
    // File mode: let the browser download the CSV
    return true;
  }
}

window.switchLoadTab = function(tab) {
  document.querySelectorAll(".load-tab").forEach(t => t.classList.remove("active"))
  document.querySelectorAll(".load-tab-content").forEach(c => { c.classList.remove("active"); c.style.display = "none" })
  const btn = document.querySelector(`.load-tab[data-tab="${tab}"]`), content = document.getElementById(`tab-${tab}`)
  if (btn) btn.classList.add("active"); if (content) { content.classList.add("active"); content.style.display = "block" }
}

window.loadFromUrl = async function() {
  const input = document.getElementById("data-url-input"), url = input ? input.value.trim() : ""
  if (!url) return
  const statusEl = document.getElementById("query-status"), loadBtn = document.getElementById("btn-load-url")

  if (window.__room_hook && window.__room_hook._duckdbReady) {
    if (loadBtn) { loadBtn.disabled = true; loadBtn.textContent = "Waiting for DuckDB..." }
    if (statusEl) statusEl.textContent = "Waiting for DuckDB to initialize..."
    await window.__room_hook._duckdbReady
    if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load" }
  }
  if (statusEl) statusEl.textContent = "Loading from URL..."
  if (loadBtn) { loadBtn.disabled = true; loadBtn.textContent = "Loading..." }

  try {
    const lower = url.toLowerCase()
    let sql
    if (lower.endsWith(".parquet") || lower.includes(".parquet?")) sql = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_parquet('${url}')`
    else if (lower.endsWith(".json") || lower.includes(".json?")) sql = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_json_auto('${url}')`
    else sql = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_csv_auto('${url}')`

    if (window.__duckdb_conn) {
      await window.__duckdb_conn.query(sql)
      const area = document.getElementById("data-load-area"); if (area) area.style.display = "none"
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load" }
      showToast("Data loaded from URL", "success")
      if (window.__room_hook) await window.__room_hook._executeQuery("SELECT * FROM data LIMIT 50")
    } else {
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load" }
      if (statusEl) statusEl.textContent = "DuckDB failed to initialize. Please reload the page."
    }
  } catch (e) {
    if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load" }
    if (statusEl) statusEl.textContent = "Error: " + e.message
    showToast("Failed to load: " + e.message, "error")
    console.error("Failed to load from URL:", e)
  }
}
