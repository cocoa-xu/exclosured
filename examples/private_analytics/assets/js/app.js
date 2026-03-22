// Private Analytics - Client-side application
// All data processing happens in the browser via DuckDB-WASM.
// The server only relays encrypted (opaque) blobs between participants.

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// SQL keyword list for syntax highlighting
const SQL_KEYWORDS = new Set([
  "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
  "AS", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS",
  "GROUP", "BY", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "HAVING",
  "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
  "DROP", "ALTER", "INDEX", "VIEW", "DISTINCT", "UNION", "ALL", "EXISTS",
  "BETWEEN", "LIKE", "CASE", "WHEN", "THEN", "ELSE", "END", "CAST",
  "WITH", "RECURSIVE", "EXCEPT", "INTERSECT", "FETCH", "FIRST", "NEXT",
  "ROWS", "ONLY", "TRUE", "FALSE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
  "CONSTRAINT", "DEFAULT", "CHECK", "UNIQUE", "TEMP", "TEMPORARY", "IF",
  "REPLACE", "OVER", "PARTITION", "WINDOW", "RANGE", "UNBOUNDED", "PRECEDING",
  "FOLLOWING", "CURRENT", "ROW", "FILTER", "QUALIFY", "PIVOT", "UNPIVOT",
  "USING", "NATURAL", "LATERAL", "TABLESAMPLE", "GROUPING", "SETS", "CUBE",
  "ROLLUP"
])

const SQL_FUNCTIONS = new Set([
  "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "IFNULL",
  "LENGTH", "UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM", "SUBSTR",
  "SUBSTRING", "REPLACE", "CONCAT", "ROUND", "FLOOR", "CEIL", "CEILING",
  "ABS", "POWER", "SQRT", "MOD", "LOG", "LN", "EXP", "RANDOM",
  "DATE", "TIME", "TIMESTAMP", "EXTRACT", "DATE_PART", "DATE_TRUNC",
  "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
  "STRFTIME", "DATE_DIFF", "AGE", "EPOCH", "YEAR", "MONTH", "DAY",
  "HOUR", "MINUTE", "SECOND", "ROW_NUMBER", "RANK", "DENSE_RANK",
  "NTILE", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
  "ARRAY_AGG", "STRING_AGG", "LIST", "STRUCT", "MAP", "TYPEOF",
  "TRY_CAST", "REGEXP_MATCHES", "REGEXP_REPLACE", "REGEXP_EXTRACT",
  "LIST_AGG", "MEDIAN", "MODE", "STDDEV", "VARIANCE", "CORR",
  "PERCENTILE_CONT", "PERCENTILE_DISC", "APPROX_COUNT_DISTINCT"
])

// Highlight SQL text and return HTML string
function highlightSQL(text) {
  if (!text) return ""
  // Escape HTML entities first
  let escaped = text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")

  // Tokenize and highlight
  return escaped.replace(
    /('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|(--.*)|((?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)\b|(\b[a-zA-Z_]\w*\b)/gi,
    (match, str, comment, num, word) => {
      if (str) return `<span class="str">${str}</span>`
      if (comment) return `<span class="comment">${comment}</span>`
      if (num) return `<span class="num">${num}</span>`
      if (word) {
        const upper = word.toUpperCase()
        if (SQL_KEYWORDS.has(upper)) return `<span class="kw">${word}</span>`
        if (SQL_FUNCTIONS.has(upper)) return `<span class="fn">${word}</span>`
      }
      return match
    }
  )
}

// Synchronize the syntax highlight overlay with the textarea
function syncSQLDisplay(textarea, display) {
  if (!textarea || !display) return
  display.innerHTML = highlightSQL(textarea.value) + "\n"
  display.scrollTop = textarea.scrollTop
  display.scrollLeft = textarea.scrollLeft
}

// Detect if a value looks numeric for right-alignment
function isNumeric(val) {
  if (val === null || val === undefined || val === "") return false
  return !isNaN(val) && !isNaN(parseFloat(val))
}

// Render a results table from column names and row data
function renderTable(tableEl, emptyEl, columns, rows, onReorder) {
  if (!tableEl) return

  if (!columns || columns.length === 0 || !rows || rows.length === 0) {
    tableEl.style.display = "none"
    if (emptyEl) {
      emptyEl.style.display = "block"
      emptyEl.textContent = "Query returned no results."
    }
    return
  }

  // Build header with cursor column + draggable data columns
  let html = '<thead><tr><th class="cursor-header"></th>'
  for (let i = 0; i < columns.length; i++) {
    html += `<th draggable="true" data-col-idx="${i}">${escapeHTML(columns[i])}</th>`
  }
  html += "</tr></thead><tbody>"

  // Build rows with empty cursor cell on the left
  for (let r = 0; r < rows.length; r++) {
    const row = rows[r]
    html += `<tr data-row-idx="${r}"><td class="cursor-cell"></td>`
    for (let i = 0; i < columns.length; i++) {
      const raw = row[columns[i]] !== undefined ? row[columns[i]] : (row[i] !== undefined ? row[i] : null)
      const val = raw !== undefined && raw !== null ? String(raw) : ""
      const cls = isNumeric(val) ? ' class="num-cell"' : ""
      html += `<td${cls}>${escapeHTML(val)}</td>`
    }
    html += "</tr>"
  }
  html += "</tbody>"

  tableEl.innerHTML = html
  tableEl.style.display = "table"
  if (emptyEl) emptyEl.style.display = "none"

  // Set up column drag-and-drop reordering
  if (onReorder) {
    let dragIdx = null
    const ths = tableEl.querySelectorAll("th[draggable]")
    ths.forEach(th => {
      th.addEventListener("dragstart", (e) => {
        dragIdx = parseInt(th.dataset.colIdx)
        th.classList.add("dragging")
        e.dataTransfer.effectAllowed = "move"
      })
      th.addEventListener("dragend", () => {
        th.classList.remove("dragging")
        dragIdx = null
      })
      th.addEventListener("dragover", (e) => {
        e.preventDefault()
        e.dataTransfer.dropEffect = "move"
        th.classList.add("drag-over")
      })
      th.addEventListener("dragleave", () => {
        th.classList.remove("drag-over")
      })
      th.addEventListener("drop", (e) => {
        e.preventDefault()
        th.classList.remove("drag-over")
        const dropIdx = parseInt(th.dataset.colIdx)
        if (dragIdx !== null && dragIdx !== dropIdx) {
          onReorder(dragIdx, dropIdx)
        }
      })
    })
  }
}

function escapeHTML(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// Show a status toast message
function showToast(message, type) {
  const toast = document.getElementById("status-toast")
  if (!toast) return
  toast.textContent = message
  toast.className = "status-toast visible" + (type ? " " + type : "")
  clearTimeout(toast._timer)
  toast._timer = setTimeout(() => {
    toast.className = "status-toast"
  }, 3000)
}

// Copy text to clipboard
function copyToClipboard(text) {
  navigator.clipboard.writeText(text).then(() => {
    showToast("Copied to clipboard", "success")
  }).catch(() => {
    // Fallback
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

// LiveView hooks
const Hooks = {}

Hooks.RoomHook = {
  async mounted() {
    this.roomId = this.el.dataset.roomId
    this._db = null
    this._conn = null
    this._pageSize = 50

    // Register event handlers FIRST (before async work)
    this.handleEvent("init_state", (data) => {
      // Determine role based on URL fragment
      const hash = window.location.hash
      if (hash && hash.length > 1) {
        // Fragment contains token info: #role=viewer&token=xxx
        const params = new URLSearchParams(hash.substring(1))
        const token = params.get("token")
        if (token) {
          this.pushEvent("join_room", {token_hash: token})
        }
      } else {
        // No fragment: this is the owner creating the room
        const viewerToken = this._generateToken()
        const editorToken = this._generateToken()
        this._viewerToken = viewerToken
        this._editorToken = editorToken
        this.pushEvent("create_room", {
          viewer_hash: viewerToken,
          editor_hash: editorToken
        })
        // Show upload area for owner
        const uploadArea = document.getElementById("data-load-area")
        if (uploadArea) uploadArea.style.display = "block"
      }
    })

    this.handleEvent("execute_query", (data) => {
      this._executeQuery(data.sql)
    })

    this.handleEvent("execute_remote_query", (data) => {
      // Owner executes a query on behalf of a remote editor
      try {
        const parsed = JSON.parse(data.sql)
        if (parsed.type === "page_change") {
          this._changePage(parsed.page)
          return
        }
      } catch (_e) {
        // Not JSON, treat as SQL
      }
      this._executeQuery(data.sql)
    })

    this.handleEvent("render_view", (data) => {
      // Viewer receives results from the owner, paginate locally
      try {
        const parsed = typeof data.data === "string" ? JSON.parse(data.data) : data.data
        if (parsed.columns && parsed.rows) {
          this._resultColumns = parsed.columns
          this._resultRows = parsed.rows
          this._currentPage = 1
          this._queryElapsed = 0
          this._renderCurrentPage()
        }
      } catch (e) {
        console.error("Failed to render view:", e)
      }
    })

    this.handleEvent("render_schema", (data) => {
      try {
        const schema = typeof data.schema === "string" ? JSON.parse(data.schema) : data.schema
        this._renderSchema(schema)
      } catch (e) {
        console.error("Failed to render schema:", e)
      }
    })

    this.handleEvent("change_page", (data) => {
      this._changePage(data.page)
    })

    this.handleEvent("set_theme", (data) => {
      document.documentElement.setAttribute("data-theme", data.theme)
    })

    // PII config change from owner (viewers receive this to know masking was updated)
    this.handleEvent("pii_config_update", (data) => {
      // The owner already re-broadcast masked results, so viewers will get
      // the updated data via render_view. This event is informational.
      const cols = data.masked_columns || []
      if (cols.length > 0) {
        showToast(`Owner updated PII masking: ${cols.length} columns`, "")
      } else {
        showToast("Owner removed PII masking", "")
      }
    })

    // Cursor presence from other users
    this._remoteCursors = []
    this.handleEvent("cursor_update", (data) => {
      this._remoteCursors = data.cursors || []
      this._renderCursors()
    })

    // Set up UI components
    this._setupSQLEditor()
    this._setupFileUpload()
    this._setupCopyButtons()
    this._setupNameInput()
    this._setupRowHover()
    this._setupHistogram()
    this._setupPiiSection()

    // Expose for URL loading
    window.__room_hook = this

    // Load the Exclosured WASM module (crypto + PII masking + histogram)
    this._wasmMod = null
    try {
      const wasmMod = await import("/wasm/private_analytics_wasm/private_analytics_wasm.js");
      await wasmMod.default("/wasm/private_analytics_wasm/private_analytics_wasm_bg.wasm");
      this._wasmMod = wasmMod;
    } catch (e) {
      console.error("Exclosured WASM load failed:", e);
      this._wasmMod = null;
    }

    // Notify server we are ready (triggers init_state which shows the upload area)
    this.pushEvent("wasm_ready", {})

    // DuckDB loading promise, resolves when ready
    this._duckdbReady = this._initDuckDB()
  },

  updated() {
    // Re-initialize UI elements that may appear after role assignment
    if (!this._sqlEditorReady) {
      const editor = document.getElementById("sql-editor")
      if (editor) {
        this._setupSQLEditor()
        this._sqlEditorReady = true
      }
    }
    if (!this._fileUploadReady) {
      const dropZone = document.getElementById("drop-zone")
      if (dropZone) {
        this._setupFileUpload()
        this._fileUploadReady = true
      }
    }
    if (!this._copyReady) {
      const btns = document.querySelectorAll("[data-copy]")
      if (btns.length > 0) {
        this._setupCopyButtons()
        this._copyReady = true
      }
    }
    if (!this._hoverReady) {
      const wrapper = document.getElementById("results-wrapper")
      if (wrapper) {
        this._setupRowHover()
        this._hoverReady = true
      }
    }
    if (!this._nameReady) {
      const nameInput = document.getElementById("display-name-input")
      if (nameInput) {
        this._setupNameInput()
        this._nameReady = true
      }
    }
    if (!this._piiReady) {
      const piiSection = document.getElementById("pii-section")
      if (piiSection) {
        this._setupPiiSection()
        this._piiReady = true
      }
    }
    if (!this._histogramReady) {
      const histSelect = document.getElementById("histogram-column")
      if (histSelect) {
        this._setupHistogram()
        this._histogramReady = true
      }
    }
  },

  _generateToken() {
    const bytes = new Uint8Array(24)
    crypto.getRandomValues(bytes)
    return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
  },

  _setupSQLEditor() {
    const editor = document.getElementById("sql-editor")
    const display = document.getElementById("sql-display")
    if (!editor || !display) return

    syncSQLDisplay(editor, display)

    editor.addEventListener("input", () => {
      syncSQLDisplay(editor, display)
      this.pushEvent("update_sql", {value: editor.value})
    })

    editor.addEventListener("scroll", () => {
      display.scrollTop = editor.scrollTop
      display.scrollLeft = editor.scrollLeft
    })

    // Ctrl/Cmd+Enter to run query
    editor.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
        e.preventDefault()
        this.pushEvent("submit_query", {sql: editor.value})
      }
    })
  },

  _setupFileUpload() {
    const dropZone = document.getElementById("drop-zone")
    const fileInput = document.getElementById("csv-file-input")
    if (!dropZone || !fileInput) return

    dropZone.addEventListener("click", () => fileInput.click())

    dropZone.addEventListener("dragover", (e) => {
      e.preventDefault()
      dropZone.style.borderColor = "var(--accent)"
    })

    dropZone.addEventListener("dragleave", () => {
      dropZone.style.borderColor = ""
    })

    dropZone.addEventListener("drop", (e) => {
      e.preventDefault()
      dropZone.style.borderColor = ""
      const files = e.dataTransfer.files
      if (files.length > 0) this._loadCSV(files[0])
    })

    fileInput.addEventListener("change", () => {
      if (fileInput.files.length > 0) this._loadCSV(fileInput.files[0])
    })
  },

  _setupCopyButtons() {
    // Delegate click for copy buttons (they may not exist yet)
    document.addEventListener("click", (e) => {
      if (e.target.id === "copy-view-url") {
        const input = document.getElementById("share-view-url")
        if (input) copyToClipboard(input.value)
      } else if (e.target.id === "copy-edit-url") {
        const input = document.getElementById("share-edit-url")
        if (input) copyToClipboard(input.value)
      }
    })

    // Update share URLs when share panel is opened
    this._updateShareURLs()
    const observer = new MutationObserver(() => this._updateShareURLs())
    observer.observe(this.el, {childList: true, subtree: true})
  },

  _updateShareURLs() {
    const viewInput = document.getElementById("share-view-url")
    const editInput = document.getElementById("share-edit-url")
    if (!viewInput || !editInput) return
    if (!this._viewerToken || !this._editorToken) return

    const base = window.location.origin + "/room/" + this.roomId
    viewInput.value = base + "#role=viewer&token=" + this._viewerToken
    editInput.value = base + "#role=editor&token=" + this._editorToken
  },

  async _loadCSV(file) {
    showToast("Loading " + file.name + "...", "")

    // Wait for DuckDB if still initializing
    if (!this._db && this._duckdbReady) {
      showToast("Waiting for DuckDB to initialize...", "")
      await this._duckdbReady
    }

    try {
      if (this._db) {
        // Read the file into an ArrayBuffer and register it with DuckDB
        const arrayBuffer = await file.arrayBuffer()
        const uint8 = new Uint8Array(arrayBuffer)
        await this._db.registerFileBuffer(file.name, uint8)

        const ext = file.name.toLowerCase()
        let createSQL
        if (ext.endsWith(".parquet")) {
          createSQL = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_parquet('${file.name}')`
        } else {
          createSQL = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_csv_auto('${file.name}')`
        }

        await this._conn.query(createSQL)

        // Get schema info
        const schemaResult = await this._conn.query("DESCRIBE data")
        const schema = []
        for (let i = 0; i < schemaResult.numRows; i++) {
          schema.push({
            name: schemaResult.getChildAt(0).get(i),
            type: schemaResult.getChildAt(1).get(i)
          })
        }
        this._schema = schema
        this._renderSchema(schema)
        this.pushEvent("schema_update", {encrypted_schema: JSON.stringify(schema)})

        // Hide upload area
        const area = document.getElementById("data-load-area")
        if (area) area.style.display = "none"

        showToast("Data loaded: " + file.name + " (" + schema.length + " columns)", "success")

        // Run initial query
        await this._executeQuery("SELECT * FROM data LIMIT 50")
      } else {
        // Fallback for CSV only (Parquet requires DuckDB)
        if (file.name.toLowerCase().endsWith(".parquet")) {
          this.pushEvent("query_error", {error: "Parquet files require DuckDB. Please reload the page and try again."})
          return
        }
        const reader = new FileReader()
        reader.onload = (e) => {
          this._parseAndLoad(e.target.result, file.name)
        }
        reader.readAsText(file)
      }
    } catch (e) {
      this.pushEvent("query_error", {error: "Failed to load file: " + e.message})
    }
  },

  _parseAndLoad(csvText, filename) {
    // Simple CSV parser for DuckDB-like behavior
    const lines = csvText.split("\n").filter(l => l.trim() !== "")
    if (lines.length === 0) {
      this.pushEvent("query_error", {error: "CSV file is empty."})
      return
    }

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

    // Hide upload area, show results
    const uploadArea = document.getElementById("data-load-area")
    if (uploadArea) uploadArea.style.display = "none"

    // Infer schema
    const schema = headers.map((h, idx) => {
      let type = "VARCHAR"
      // Sample a few rows to infer type
      for (let r = 0; r < Math.min(10, rows.length); r++) {
        const val = rows[r][idx]
        if (val === undefined || val === null || val === "") continue
        if (!isNaN(val) && val.includes(".")) { type = "DOUBLE"; break }
        if (!isNaN(val) && !isNaN(parseInt(val))) { type = "BIGINT"; break }
      }
      return {name: h, type: type}
    })

    this._schema = schema
    this._renderSchema(schema)
    this.pushEvent("schema_update", {encrypted_schema: JSON.stringify(schema)})

    // Execute default query
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
          if (i + 1 < line.length && line[i + 1] === '"') {
            current += '"'
            i++
          } else {
            inQuotes = false
          }
        } else {
          current += ch
        }
      } else {
        if (ch === '"') {
          inQuotes = true
        } else if (ch === ',') {
          result.push(current.trim())
          current = ""
        } else {
          current += ch
        }
      }
    }
    result.push(current.trim())
    return result
  },

  async _initDuckDB() {
    const status = document.getElementById("query-status");
    const loadBtn = document.getElementById("btn-load-url");

    try {
      showToast("Loading DuckDB engine...", "");
      if (status) status.textContent = "Downloading DuckDB engine...";
      if (loadBtn) { loadBtn.disabled = true; loadBtn.textContent = "Loading DuckDB..."; }

      // Use +esm suffix to let jsdelivr resolve the apache-arrow dependency
      const duckdb = await import(/* webpackIgnore: true */ "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/+esm");

      if (status) status.textContent = "Initializing DuckDB...";
      const bundles = duckdb.getJsDelivrBundles();
      const bundle = await duckdb.selectBundle(bundles);

      const logger = new duckdb.ConsoleLogger();
      const worker = await duckdb.createWorker(bundle.mainWorker);
      const db = new duckdb.AsyncDuckDB(logger, worker);
      await db.instantiate(bundle.mainModule);

      this._db = db;
      this._conn = await db.connect();
      window.__duckdb_conn = this._conn;

      if (status) status.textContent = "DuckDB ready";
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load"; }
      showToast("DuckDB ready", "success");
    } catch (e) {
      console.error("DuckDB init failed:", e);
      if (status) status.textContent = "DuckDB failed to load";
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load"; }
      showToast("DuckDB failed to load: " + e.message, "error");
      this._db = null;
      this._conn = null;
    }
  },

  async _executeQuery(sql) {
    // Wait for DuckDB if still initializing
    if (!this._conn && this._duckdbReady) {
      showToast("Waiting for DuckDB...", "");
      await this._duckdbReady;
    }
    if (!this._conn) {
      this.pushEvent("query_error", {error: "DuckDB not loaded. Please reload the page."})
      return
    }

    try {
      const start = performance.now()
      const result = await this._conn.query(sql)
      const elapsed = Math.round(performance.now() - start)

      // Convert Arrow result to plain JS arrays, handling BigInt
      const columns = result.schema.fields.map(f => f.name)
      const allRows = []
      for (let i = 0; i < result.numRows; i++) {
        const row = {}
        for (let c = 0; c < columns.length; c++) {
          let val = result.getChildAt(c).get(i)
          if (typeof val === "bigint") {
            val = (val >= Number.MIN_SAFE_INTEGER && val <= Number.MAX_SAFE_INTEGER)
              ? Number(val) : val.toString()
          }
          row[columns[c]] = val
        }
        allRows.push(row)
      }

      // Store full result set for local pagination
      this._resultColumns = columns
      this._resultRows = allRows
      this._localColumnOrder = null  // reset custom order on new query
      this._currentPage = 1
      this._queryElapsed = elapsed

      // Render current page
      this._renderCurrentPage()

      // Broadcast to viewers with PII masking applied on selected columns
      this._broadcastMaskedResults(columns, allRows)

      // Update editor display
      const editor = document.getElementById("sql-editor")
      if (editor) {
        editor.value = sql
        const display = document.getElementById("sql-display")
        syncSQLDisplay(editor, display)
      }
    } catch (e) {
      this.pushEvent("query_error", {error: "Query error: " + e.message})
    }
  },

  _renderCurrentPage() {
    if (!this._resultColumns || !this._resultRows) return

    const rows = this._resultRows
    // Use local column order if set, otherwise original order
    const columns = this._localColumnOrder || this._resultColumns
    const pageSize = this._pageSize || 50
    const page = this._currentPage || 1
    const totalRows = rows.length
    const totalPages = Math.max(1, Math.ceil(totalRows / pageSize))
    const startIdx = (page - 1) * pageSize
    let pageRows = rows.slice(startIdx, startIdx + pageSize)

    // Apply self-masking if enabled and columns are selected
    const selfMask = document.getElementById("pii-mask-self")
    const maskedCols = this._piiMaskedColumns || []
    if (selfMask && selfMask.checked && maskedCols.length > 0) {
      pageRows = pageRows.map(row => {
        const masked = {...row}
        for (const col of maskedCols) {
          if (masked[col] != null) masked[col] = this._maskValue(String(masked[col]))
        }
        return masked
      })
    }

    // Render table with drag-to-reorder columns
    const table = document.getElementById("results-table")
    const empty = document.getElementById("results-empty")
    renderTable(table, empty, columns, pageRows, (fromIdx, toIdx) => {
      // Reorder columns locally
      const order = [...columns]
      const [moved] = order.splice(fromIdx, 1)
      order.splice(toIdx, 0, moved)
      this._localColumnOrder = order
      this._renderCurrentPage()
    })

    // Re-render cursor indicators for the new page
    this._renderCursors()

    // Update status
    const status = document.getElementById("query-status")
    if (status) {
      status.textContent = `${totalRows} total rows, ${this._queryElapsed || 0}ms`
    }

    // Populate histogram column selector
    const histSelect = document.getElementById("histogram-column")
    if (histSelect && this._resultColumns) {
      histSelect.innerHTML = '<option value="">Select a column</option>' +
        this._resultColumns.map(c => `<option value="${escapeHTML(c)}">${escapeHTML(c)}</option>`).join("")
    }

    // Update PII indicator and column chips
    const piiIndicator = document.getElementById("pii-indicator")
    if (piiIndicator) {
      if (maskedCols.length > 0) {
        piiIndicator.textContent = `${maskedCols.length} columns masked`
        piiIndicator.style.display = "inline"
      } else {
        piiIndicator.style.display = "none"
      }
    }
    this._renderPiiColumns()

    // Update pagination controls
    this._renderPagination(page, totalPages, totalRows, pageSize)
  },

  _renderPagination(page, totalPages, totalRows, pageSize) {
    let container = document.getElementById("local-pagination")
    if (!container) {
      // Create pagination container after the results
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
      </div>
    `

    document.getElementById("pg-prev").onclick = () => {
      if (this._currentPage > 1) { this._currentPage--; this._renderCurrentPage() }
    }
    document.getElementById("pg-next").onclick = () => {
      const maxPage = Math.ceil(this._resultRows.length / (this._pageSize || 50))
      if (this._currentPage < maxPage) { this._currentPage++; this._renderCurrentPage() }
    }
    document.getElementById("pg-size").onchange = (e) => {
      this._pageSize = parseInt(e.target.value)
      this._currentPage = 1
      this._renderCurrentPage()
    }
    const resetBtn = document.getElementById("pg-reset-cols")
    if (resetBtn) {
      resetBtn.onclick = () => {
        this._localColumnOrder = null
        this._renderCurrentPage()
      }
    }
  },

  _runSimpleSQL(sql) {
    // Basic SQL parser for SELECT queries on the loaded CSV data.
    // Supports: SELECT columns FROM data [WHERE ...] [ORDER BY ...] [LIMIT n] [OFFSET n]
    const normalized = sql.replace(/\s+/g, " ").trim()
    const upperSQL = normalized.toUpperCase()

    if (!upperSQL.startsWith("SELECT")) {
      throw new Error("Only SELECT queries are supported in this demo.")
    }

    let columns = this._tableColumns
    let rows = [...this._tableRows]

    // Parse LIMIT
    let limit = rows.length
    const limitMatch = upperSQL.match(/LIMIT\s+(\d+)/)
    if (limitMatch) limit = parseInt(limitMatch[1])

    // Parse OFFSET
    let offset = 0
    const offsetMatch = upperSQL.match(/OFFSET\s+(\d+)/)
    if (offsetMatch) offset = parseInt(offsetMatch[1])

    // Parse column selection
    const fromIdx = upperSQL.indexOf(" FROM ")
    const selectPart = fromIdx > 0
      ? normalized.substring(7, fromIdx).trim()
      : normalized.substring(7).trim()

    let selectedCols = columns
    let selectedIndices = columns.map((_, i) => i)

    if (selectPart !== "*") {
      const colNames = selectPart.split(",").map(c => c.trim())
      selectedIndices = []
      selectedCols = []
      for (const cn of colNames) {
        // Handle "col AS alias" syntax
        const asMatch = cn.match(/^(.+?)\s+AS\s+(.+)$/i)
        const colName = asMatch ? asMatch[1].trim() : cn
        const alias = asMatch ? asMatch[2].trim() : cn
        const idx = columns.findIndex(c => c.toLowerCase() === colName.toLowerCase())
        if (idx >= 0) {
          selectedIndices.push(idx)
          selectedCols.push(alias)
        } else if (colName.toUpperCase() === "COUNT(*)") {
          // Aggregate: count
          return {
            columns: [alias],
            rows: [[rows.length]],
            totalRows: 1
          }
        }
      }
    }

    // Parse simple WHERE clause
    const whereIdx = upperSQL.indexOf(" WHERE ")
    if (whereIdx > 0) {
      let endIdx = upperSQL.length
      for (const kw of [" ORDER ", " LIMIT ", " OFFSET ", " GROUP "]) {
        const ki = upperSQL.indexOf(kw, whereIdx + 7)
        if (ki > 0 && ki < endIdx) endIdx = ki
      }
      const whereClause = normalized.substring(
        whereIdx + 7,
        endIdx - (normalized.length - upperSQL.length) + (upperSQL.length - normalized.length)
      ).trim()

      // The WHERE clause extraction needs the original (non-upper) offset
      const whereOriginal = normalized.substring(whereIdx + 7 - (normalized.length - normalized.length), endIdx).trim()
      rows = this._filterRows(rows, columns, whereOriginal || whereClause)
    }

    // Parse ORDER BY
    const orderIdx = upperSQL.indexOf(" ORDER BY ")
    if (orderIdx > 0) {
      let endIdx = upperSQL.length
      for (const kw of [" LIMIT ", " OFFSET "]) {
        const ki = upperSQL.indexOf(kw, orderIdx + 10)
        if (ki > 0 && ki < endIdx) endIdx = ki
      }
      const orderClause = normalized.substring(orderIdx + 10, endIdx).trim()
      rows = this._sortRows(rows, columns, orderClause)
    }

    const totalRows = rows.length

    // Apply offset and limit
    rows = rows.slice(offset, offset + limit)

    // Project columns
    const projectedRows = rows.map(row =>
      selectedIndices.map(i => row[i] !== undefined ? row[i] : "")
    )

    return {columns: selectedCols, rows: projectedRows, totalRows}
  },

  _filterRows(rows, columns, whereClause) {
    // Simple single-condition WHERE filter
    // Supports: col = 'value', col > N, col < N, col LIKE '%pattern%'
    const likeMatch = whereClause.match(/^(\w+)\s+LIKE\s+'(.+)'$/i)
    if (likeMatch) {
      const colIdx = columns.findIndex(c => c.toLowerCase() === likeMatch[1].toLowerCase())
      if (colIdx < 0) return rows
      const pattern = likeMatch[2].replace(/%/g, ".*").replace(/_/g, ".")
      const re = new RegExp("^" + pattern + "$", "i")
      return rows.filter(r => re.test(r[colIdx] || ""))
    }

    const cmpMatch = whereClause.match(/^(\w+)\s*(=|!=|<>|>=|<=|>|<)\s*'?([^']*)'?$/i)
    if (cmpMatch) {
      const colIdx = columns.findIndex(c => c.toLowerCase() === cmpMatch[1].toLowerCase())
      if (colIdx < 0) return rows
      const op = cmpMatch[2]
      const val = cmpMatch[3]

      return rows.filter(r => {
        const cell = r[colIdx] || ""
        const numCell = parseFloat(cell)
        const numVal = parseFloat(val)
        const useNum = !isNaN(numCell) && !isNaN(numVal)

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

    // Fallback: return all rows if we cannot parse the WHERE clause
    return rows
  },

  _sortRows(rows, columns, orderClause) {
    const parts = orderClause.split(",").map(p => p.trim())
    const sortKeys = parts.map(p => {
      const tokens = p.split(/\s+/)
      const colName = tokens[0]
      const dir = (tokens[1] || "ASC").toUpperCase() === "DESC" ? -1 : 1
      const idx = columns.findIndex(c => c.toLowerCase() === colName.toLowerCase())
      return {idx, dir}
    }).filter(k => k.idx >= 0)

    return rows.sort((a, b) => {
      for (const {idx, dir} of sortKeys) {
        const va = a[idx] || ""
        const vb = b[idx] || ""
        const na = parseFloat(va)
        const nb = parseFloat(vb)
        if (!isNaN(na) && !isNaN(nb)) {
          if (na !== nb) return (na - nb) * dir
        } else {
          const cmp = va.localeCompare(vb)
          if (cmp !== 0) return cmp * dir
        }
      }
      return 0
    })
  },

  _changePage(page) {
    if (!this._tableRows) return
    const pageSize = this._pageSize || 50
    const offset = (page - 1) * pageSize
    const sql = "SELECT * FROM data LIMIT " + pageSize + " OFFSET " + offset
    this._executeLocalQuery(sql)
  },

  _renderSchema(schema) {
    const container = document.getElementById("schema-list")
    if (!container || !schema) return

    let html = `<div class="schema-count">${schema.length} columns</div>`
    for (const col of schema) {
      html += `<div class="schema-col">
        <span class="schema-col-name">${escapeHTML(col.name)}</span>
        <span class="schema-col-type">${escapeHTML(col.type)}</span>
      </div>`
    }
    container.innerHTML = html
  },

  _setupNameInput() {
    const input = document.getElementById("display-name-input")
    if (!input) return
    let debounce = null
    input.addEventListener("input", () => {
      clearTimeout(debounce)
      debounce = setTimeout(() => {
        this.pushEvent("set_display_name", {name: input.value.trim() || "Anonymous"})
      }, 300)
    })
  },

  _setupRowHover() {
    const wrapper = document.getElementById("results-wrapper")
    if (!wrapper) return
    this._pinnedRow = null  // absolute row index when pinned
    let lastRow = null

    wrapper.addEventListener("mouseover", (e) => {
      if (this._pinnedRow !== null) return
      const tr = e.target.closest("tbody tr")
      if (!tr) return
      const rowIdx = parseInt(tr.dataset.rowIdx)
      if (isNaN(rowIdx) || rowIdx === lastRow) return
      lastRow = rowIdx
      const page = this._currentPage || 1
      const pageSize = this._pageSize || 50
      const absRow = (page - 1) * pageSize + rowIdx
      this._myHoverRow = absRow
      this._renderCursors()
      this.pushEvent("cursor_hover", {row: absRow, page: page, page_size: pageSize})
    })

    wrapper.addEventListener("mouseleave", () => {
      if (this._pinnedRow !== null) return
      lastRow = null
      this._myHoverRow = -1
      this._renderCursors()
      this.pushEvent("cursor_hover", {row: -1, page: this._currentPage || 1, page_size: this._pageSize || 50})
    })

    // Click to pin/unpin cursor on a row
    wrapper.addEventListener("click", (e) => {
      const tr = e.target.closest("tbody tr")
      if (!tr) return
      // Ignore clicks on cursor dots themselves
      if (e.target.closest(".cursor-dot, .cursor-indicators")) return

      const rowIdx = parseInt(tr.dataset.rowIdx)
      if (isNaN(rowIdx)) return
      const page = this._currentPage || 1
      const pageSize = this._pageSize || 50
      const absRow = (page - 1) * pageSize + rowIdx

      if (this._pinnedRow === absRow) {
        this._pinnedRow = null
        this._myHoverRow = -1
        this._renderCursors()
        this.pushEvent("cursor_hover", {row: -1, page: page, page_size: pageSize})
      } else {
        this._pinnedRow = absRow
        this._myHoverRow = absRow
        this._renderCursors()
        this.pushEvent("cursor_hover", {row: absRow, page: page, page_size: pageSize})
      }
    })
  },

  _renderCursors() {
    const table = document.getElementById("results-table")
    if (!table) return

    // Clear cursor cell contents (cells are built into the table, just clear them)
    table.querySelectorAll(".cursor-cell").forEach(el => { el.innerHTML = "" })
    table.querySelectorAll(".has-cursors").forEach(el => el.classList.remove("has-cursors"))
    document.querySelectorAll(".offpage-cursor").forEach(el => el.remove())

    const myPage = this._currentPage || 1
    const myPageSize = this._pageSize || 50
    const myStart = (myPage - 1) * myPageSize
    const myEnd = myStart + myPageSize
    const myHover = this._myHoverRow != null ? this._myHoverRow : -1

    const onPage = []
    const abovePage = []
    const belowPage = []

    const remoteCursors = this._remoteCursors || []
    for (const c of remoteCursors) {
      if (c.row == null || c.row < 0) continue
      if (c.row < myStart) {
        abovePage.push(c)
      } else if (c.row >= myEnd) {
        belowPage.push(c)
      } else {
        onPage.push({...c, localRow: c.row - myStart})
      }
    }

    // Add local user's cursor (if hovering on this page)
    if (myHover >= myStart && myHover < myEnd) {
      onPage.push({
        name: "You",
        color: "#ffffff",
        localRow: myHover - myStart,
        isMe: true
      })
    }

    // Fill cursor dots into existing cursor cells
    const tbody = table.querySelector("tbody")
    if (tbody) {
      const rows = tbody.querySelectorAll("tr")
      const byRow = {}
      for (const c of onPage) {
        if (!byRow[c.localRow]) byRow[c.localRow] = []
        byRow[c.localRow].push(c)
      }

      for (const [rowIdx, cursors] of Object.entries(byRow)) {
        const tr = rows[parseInt(rowIdx)]
        if (!tr) continue
        tr.classList.add("has-cursors")

        const cell = tr.querySelector(".cursor-cell")
        if (!cell) continue

        const names = cursors.map(c => c.name).join(", ")
        const container = document.createElement("div")
        container.className = "cursor-indicators"
        container.setAttribute("data-tooltip", names)

        for (const c of cursors) {
          const dot = document.createElement("div")
          if (c.isMe) {
            dot.className = "cursor-dot cursor-dot-me"
          } else {
            dot.className = "cursor-dot"
            dot.style.backgroundColor = c.color
          }
          container.appendChild(dot)
        }
        cell.appendChild(container)
      }
    }

    // Render off-page cursors (above)
    const wrapper = document.getElementById("results-wrapper")
    if (wrapper && abovePage.length > 0) {
      const banner = document.createElement("div")
      banner.className = "offpage-cursor"
      banner.innerHTML = abovePage.map(c =>
        `<span class="offpage-dot" style="background:${c.color}"></span> ${escapeHTML(c.name)} on row ${c.row + 1}`
      ).join(", ")
      wrapper.insertBefore(banner, wrapper.firstChild)
    }

    // Render off-page cursors (below)
    if (wrapper && belowPage.length > 0) {
      const banner = document.createElement("div")
      banner.className = "offpage-cursor"
      banner.innerHTML = belowPage.map(c =>
        `<span class="offpage-dot" style="background:${c.color}"></span> ${escapeHTML(c.name)} on row ${c.row + 1}`
      ).join(", ")
      wrapper.appendChild(banner)
    }
  },

  _setupPiiSection() {
    const section = document.getElementById("pii-section")
    if (!section) return

    // "Also mask in my own view" re-renders with masking applied
    const selfMask = document.getElementById("pii-mask-self")
    if (selfMask) {
      selfMask.addEventListener("change", () => {
        this._renderCurrentPage()
      })
    }

    // Auto-detect button
    const autoBtn = document.getElementById("pii-auto-detect")
    if (autoBtn) {
      autoBtn.addEventListener("click", () => {
        this._autoDetectPii()
      })
    }

    // Select all / clear all
    const selectAll = document.getElementById("pii-select-all")
    const selectNone = document.getElementById("pii-select-none")
    if (selectAll) {
      selectAll.addEventListener("click", () => {
        this._piiMaskedColumns = [...(this._resultColumns || [])]
        this._renderPiiColumns()
        this._onPiiColumnsChanged()
      })
    }
    if (selectNone) {
      selectNone.addEventListener("click", () => {
        this._piiMaskedColumns = []
        this._renderPiiColumns()
        this._onPiiColumnsChanged()
      })
    }
  },

  _renderPiiColumns() {
    const container = document.getElementById("pii-column-list")
    if (!container || !this._resultColumns) return

    const masked = this._piiMaskedColumns || []
    const autoDetected = this._piiAutoDetected || []

    container.innerHTML = this._resultColumns.map(col => {
      const isSelected = masked.includes(col)
      const isAuto = autoDetected.includes(col)
      const cls = ["pii-chip"]
      if (isSelected) cls.push("selected")
      if (isAuto) cls.push("auto-detected")

      return `<label class="${cls.join(" ")}" data-col="${escapeHTML(col)}">
        <span class="pii-chip-dot"></span>
        <span>${escapeHTML(col)}</span>
        <input type="checkbox" ${isSelected ? "checked" : ""} />
      </label>`
    }).join("")

    // Add count
    const countEl = container.parentElement.querySelector(".pii-masked-count")
    if (countEl) {
      countEl.textContent = masked.length > 0 ? `${masked.length} of ${this._resultColumns.length} columns will be masked` : ""
    } else if (masked.length > 0) {
      const p = document.createElement("p")
      p.className = "pii-masked-count"
      p.textContent = `${masked.length} of ${this._resultColumns.length} columns will be masked`
      container.parentElement.appendChild(p)
    }

    // Click handlers on chips
    container.querySelectorAll(".pii-chip").forEach(chip => {
      chip.addEventListener("click", (e) => {
        e.preventDefault()
        const col = chip.dataset.col
        const idx = this._piiMaskedColumns.indexOf(col)
        if (idx >= 0) {
          this._piiMaskedColumns.splice(idx, 1)
        } else {
          this._piiMaskedColumns.push(col)
        }
        this._renderPiiColumns()
        this._onPiiColumnsChanged()
      })
    })
  },

  _onPiiColumnsChanged() {
    const cols = this._piiMaskedColumns || []

    // Re-render own view immediately
    this._renderCurrentPage()

    // Notify server (broadcasts to all viewers)
    this.pushEvent("pii_columns_changed", {columns: cols})

    // Re-broadcast current results with new masking
    if (this._resultColumns && this._resultRows) {
      this._broadcastMaskedResults(this._resultColumns, this._resultRows)
    }
  },

  _autoDetectPii() {
    if (!this._resultRows || !this._resultColumns || !this._wasmMod) return

    const detected = []
    const sampleSize = Math.min(100, this._resultRows.length)

    for (const col of this._resultColumns) {
      let piiCount = 0
      for (let i = 0; i < sampleSize; i++) {
        const val = String(this._resultRows[i][col] || "")
        if (!val) continue
        // Check common PII patterns
        if (val.includes("@") && val.includes(".")) piiCount++             // email
        else if (/\d{3}-\d{2}-\d{4}/.test(val)) piiCount++                // SSN
        else if (/\d{3}[-.\s]\d{3}[-.\s]\d{4}/.test(val)) piiCount++      // phone
        else if (/\d{13,19}/.test(val.replace(/[\s-]/g, ""))) piiCount++   // credit card
      }
      // If more than 10% of samples look like PII, flag this column
      if (piiCount > sampleSize * 0.1) {
        detected.push(col)
      }
    }

    this._piiAutoDetected = detected
    this._piiMaskedColumns = [...detected]
    this._renderPiiColumns()
    this._onPiiColumnsChanged()

    const status = document.getElementById("analysis-status")
    if (detected.length > 0) {
      showToast(`Auto-detected ${detected.length} PII column${detected.length > 1 ? "s" : ""}: ${detected.join(", ")}`, "success")
    } else {
      showToast("No PII patterns detected in the data", "")
    }
  },

  _broadcastMaskedResults(columns, allRows) {
    const maskedCols = this._piiMaskedColumns || []
    let broadcastData
    if (maskedCols.length > 0) {
      broadcastData = this._applySelectiveMasking(columns, allRows, maskedCols)
    } else {
      broadcastData = JSON.stringify({columns, rows: allRows})
    }
    this.pushEvent("query_result", {
      data: broadcastData,
      total_rows: allRows.length
    })
  },

  _applySelectiveMasking(columns, rows, maskedCols) {
    // Create a copy with only selected columns masked
    const maskedRows = rows.map(row => {
      const newRow = {...row}
      for (const col of maskedCols) {
        if (newRow[col] != null) {
          newRow[col] = this._maskValue(String(newRow[col]))
        }
      }
      return newRow
    })
    return JSON.stringify({columns, rows: maskedRows})
  },

  _maskValue(val) {
    if (val === null || val === undefined || val === "") return val

    const s = String(val)

    // Known PII patterns get smart masking
    // Email
    if (s.includes("@") && s.includes(".")) {
      return s.replace(/^(.).*(@.).*(\.[^.]+)$/, "$1***$2***$3")
    }
    // SSN (NNN-NN-NNNN)
    if (/^\d{3}-\d{2}-\d{4}$/.test(s)) {
      return "***-**-" + s.slice(-4)
    }
    // Phone (NNN-NNN-NNNN or similar)
    if (/^\d{3}[-.\s]\d{3}[-.\s]\d{4}$/.test(s)) {
      return "***-***-" + s.slice(-4)
    }
    // Credit card (13-19 digits)
    const digitsOnly = s.replace(/[\s-]/g, "")
    if (/^\d{13,19}$/.test(digitsOnly)) {
      return "*".repeat(digitsOnly.length - 4) + digitsOnly.slice(-4)
    }

    // Generic masking for explicitly selected columns:
    // Numbers: replace with "***"
    if (!isNaN(Number(s)) && s.trim() !== "") {
      return "***"
    }
    // Short strings (1-3 chars): fully mask
    if (s.length <= 3) {
      return "**"
    }
    // Longer strings: show first char + mask + last char
    return s[0] + "*".repeat(Math.min(s.length - 2, 8)) + s[s.length - 1]
  },

  _setupHistogram() {
    const select = document.getElementById("histogram-column")
    if (!select) return

    select.addEventListener("change", () => {
      const colName = select.value
      if (!colName || !this._resultRows || !this._wasmMod) {
        // Clear analysis display
        const canvas = document.getElementById("histogram-canvas")
        if (canvas) canvas.style.display = "none"
        const statsEl = document.getElementById("column-stats")
        if (statsEl) statsEl.innerHTML = ""
        const statusEl = document.getElementById("analysis-status")
        if (statusEl) statusEl.textContent = ""
        return
      }

      const statusEl = document.getElementById("analysis-status")
      if (statusEl) statusEl.textContent = "Analyzing..."

      // Extract column values
      const values = this._resultRows.map(r => r[colName])
      const isNumeric = values.some(v => typeof v === "number")

      if (isNumeric) {
        try {
          const numValues = values.filter(v => typeof v === "number")
          const histJson = this._wasmMod.compute_histogram(JSON.stringify(numValues), 20)
          const hist = JSON.parse(histJson)
          this._drawHistogram(hist)
        } catch (e) {
          console.error("Histogram computation failed:", e)
          const canvas = document.getElementById("histogram-canvas")
          if (canvas) canvas.style.display = "none"
        }
      } else {
        const canvas = document.getElementById("histogram-canvas")
        if (canvas) canvas.style.display = "none"
      }

      // Profile column
      try {
        const profileJson = this._wasmMod.profile_column(
          JSON.stringify(values),
          isNumeric ? "numeric" : "text"
        )
        const profile = JSON.parse(profileJson)
        this._renderProfile(profile, isNumeric)
      } catch (e) {
        console.error("Column profiling failed:", e)
      }

      if (statusEl) statusEl.textContent = ""
    })
  },

  _drawHistogram(hist) {
    const canvas = document.getElementById("histogram-canvas")
    if (!canvas) return
    canvas.style.display = "block"
    const ctx = canvas.getContext("2d")
    const W = canvas.width
    const H = canvas.height
    const padding = {top: 20, right: 20, bottom: 40, left: 50}

    // Clear canvas
    ctx.clearRect(0, 0, W, H)

    // Use theme colors
    const isDark = document.documentElement.getAttribute("data-theme") !== "light"
    const textColor = isDark ? "#888" : "#777"
    const barColor = isDark ? "rgba(79, 148, 239, 0.7)" : "rgba(79, 148, 239, 0.8)"
    const barBorder = isDark ? "rgba(79, 148, 239, 0.9)" : "rgba(79, 148, 239, 1.0)"
    const gridColor = isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.06)"

    const bins = hist.bins || hist
    if (!bins || bins.length === 0) return

    const counts = bins.map(b => b.count || 0)
    const maxCount = Math.max(...counts, 1)

    const chartW = W - padding.left - padding.right
    const chartH = H - padding.top - padding.bottom
    const barW = chartW / bins.length
    const gap = Math.max(1, barW * 0.1)

    // Draw horizontal grid lines
    ctx.strokeStyle = gridColor
    ctx.lineWidth = 1
    const numGridLines = 4
    for (let i = 1; i <= numGridLines; i++) {
      const y = padding.top + chartH - (chartH * i / numGridLines)
      ctx.beginPath()
      ctx.moveTo(padding.left, y)
      ctx.lineTo(W - padding.right, y)
      ctx.stroke()
    }

    // Draw bars
    for (let i = 0; i < bins.length; i++) {
      const count = counts[i]
      const barH = (count / maxCount) * chartH
      const x = padding.left + i * barW + gap / 2
      const y = padding.top + chartH - barH

      ctx.fillStyle = barColor
      ctx.fillRect(x, y, barW - gap, barH)
      ctx.strokeStyle = barBorder
      ctx.lineWidth = 1
      ctx.strokeRect(x, y, barW - gap, barH)
    }

    // Draw axes
    ctx.strokeStyle = textColor
    ctx.lineWidth = 1
    ctx.beginPath()
    // Y axis
    ctx.moveTo(padding.left, padding.top)
    ctx.lineTo(padding.left, padding.top + chartH)
    // X axis
    ctx.lineTo(W - padding.right, padding.top + chartH)
    ctx.stroke()

    // Y axis labels
    ctx.fillStyle = textColor
    ctx.font = "10px system-ui, sans-serif"
    ctx.textAlign = "right"
    ctx.textBaseline = "middle"
    for (let i = 0; i <= numGridLines; i++) {
      const val = Math.round(maxCount * i / numGridLines)
      const y = padding.top + chartH - (chartH * i / numGridLines)
      ctx.fillText(String(val), padding.left - 5, y)
    }

    // X axis labels (show first, middle, last bin edges)
    ctx.textAlign = "center"
    ctx.textBaseline = "top"
    const labelPositions = [0, Math.floor(bins.length / 2), bins.length - 1]
    for (const idx of labelPositions) {
      if (idx < bins.length) {
        const b = bins[idx]
        const label = typeof b.min === "number" ? b.min.toFixed(1) : String(b.min || "")
        const x = padding.left + idx * barW + barW / 2
        ctx.fillText(label, x, padding.top + chartH + 5)
      }
    }
    // Show the last bin's max on the far right
    if (bins.length > 0) {
      const lastBin = bins[bins.length - 1]
      const label = typeof lastBin.max === "number" ? lastBin.max.toFixed(1) : String(lastBin.max || "")
      ctx.textAlign = "right"
      ctx.fillText(label, W - padding.right, padding.top + chartH + 5)
    }
  },

  _renderProfile(profile, isNumeric) {
    const statsEl = document.getElementById("column-stats")
    if (!statsEl) return

    let html = ""
    if (isNumeric) {
      // Numeric stats
      const entries = [
        ["Count", profile.count],
        ["Min", profile.min],
        ["Max", profile.max],
        ["Mean", typeof profile.mean === "number" ? profile.mean.toFixed(4) : profile.mean],
        ["Median", typeof profile.median === "number" ? profile.median.toFixed(4) : profile.median],
        ["Std Dev", typeof profile.std_dev === "number" ? profile.std_dev.toFixed(4) : profile.std_dev],
        ["Nulls", profile.null_count]
      ]
      html = '<div class="stats-grid">'
      for (const [label, value] of entries) {
        if (value !== undefined && value !== null) {
          html += `<div class="stat-item"><span class="stat-label">${escapeHTML(label)}</span><span class="stat-value">${escapeHTML(String(value))}</span></div>`
        }
      }
      html += '</div>'
    } else {
      // Text profile: top values
      html = '<div class="stats-grid">'
      if (profile.count !== undefined) {
        html += `<div class="stat-item"><span class="stat-label">Count</span><span class="stat-value">${profile.count}</span></div>`
      }
      if (profile.unique !== undefined) {
        html += `<div class="stat-item"><span class="stat-label">Unique</span><span class="stat-value">${profile.unique}</span></div>`
      }
      if (profile.null_count !== undefined) {
        html += `<div class="stat-item"><span class="stat-label">Nulls</span><span class="stat-value">${profile.null_count}</span></div>`
      }
      html += '</div>'

      if (profile.top_values && profile.top_values.length > 0) {
        html += '<div class="top-values"><div class="stat-label" style="margin-bottom:0.3rem;">Top values</div>'
        for (const tv of profile.top_values.slice(0, 10)) {
          const pct = profile.count > 0 ? ((tv.count / profile.count) * 100).toFixed(1) : "0"
          html += `<div class="top-value-row">`
          html += `<span class="top-value-name">${escapeHTML(String(tv.value))}</span>`
          html += `<span class="top-value-bar"><span class="top-value-fill" style="width:${pct}%"></span></span>`
          html += `<span class="top-value-count">${tv.count} (${pct}%)</span>`
          html += `</div>`
        }
        html += '</div>'
      }
    }

    statsEl.innerHTML = html
  },

  destroyed() {
    // Cleanup
    window.__room_hook = null
  }
}

// Connect LiveSocket
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()

// Close share popover when clicking outside
document.addEventListener("click", (e) => {
  const popover = document.querySelector(".share-popover")
  if (!popover) return
  const container = document.querySelector(".share-popover-container")
  if (container && !container.contains(e.target)) {
    // Click outside, close it
    if (window.__room_hook) {
      window.__room_hook.pushEvent("toggle_share", {})
    }
  }
})

// Expose for debugging
window.liveSocket = liveSocket

// Toggle PII subsection
window.togglePiiSection = function() {
  const body = document.getElementById("pii-config")
  const icon = document.getElementById("pii-collapse-icon")
  if (!body) return
  body.classList.toggle("collapsed")
  if (icon) {
    icon.innerHTML = body.classList.contains("collapsed") ? "&#9654;" : "&#9660;"
  }
}

// Toggle schema panel visibility
window.toggleSchema = function() {
  const container = document.getElementById("schema-container");
  const icon = document.getElementById("schema-collapse-icon");
  if (!container) return;
  container.classList.toggle("collapsed");
  if (icon) {
    icon.innerHTML = container.classList.contains("collapsed") ? "&#9654;" : "&#9660;";
  }
}

// Tab switching for data loading (file vs URL)
window.switchLoadTab = function(tab) {
  document.querySelectorAll(".load-tab").forEach(t => t.classList.remove("active"));
  document.querySelectorAll(".load-tab-content").forEach(c => {
    c.classList.remove("active");
    c.style.display = "none";
  });
  const btn = document.querySelector(`.load-tab[data-tab="${tab}"]`);
  const content = document.getElementById(`tab-${tab}`);
  if (btn) btn.classList.add("active");
  if (content) { content.classList.add("active"); content.style.display = "block"; }
}

// Load data from a URL via DuckDB
window.loadFromUrl = async function() {
  const input = document.getElementById("data-url-input");
  const url = input ? input.value.trim() : "";
  if (!url) return;

  const statusEl = document.getElementById("query-status");
  const loadBtn = document.getElementById("btn-load-url");

  // Wait for DuckDB to finish loading if it's still initializing
  if (window.__room_hook && window.__room_hook._duckdbReady) {
    if (loadBtn) { loadBtn.disabled = true; loadBtn.textContent = "Waiting for DuckDB..."; }
    if (statusEl) statusEl.textContent = "Waiting for DuckDB to initialize...";
    await window.__room_hook._duckdbReady;
    if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load"; }
  }

  if (statusEl) statusEl.textContent = "Loading from URL...";
  if (loadBtn) { loadBtn.disabled = true; loadBtn.textContent = "Loading..."; }

  try {
    // Determine file type from URL extension
    const lower = url.toLowerCase();
    let sql;
    if (lower.endsWith(".parquet") || lower.includes(".parquet?")) {
      sql = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_parquet('${url}')`;
    } else if (lower.endsWith(".json") || lower.includes(".json?")) {
      sql = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_json_auto('${url}')`;
    } else {
      // Default: treat as CSV
      sql = `CREATE OR REPLACE TABLE data AS SELECT * FROM read_csv_auto('${url}')`;
    }

    if (window.__duckdb_conn) {
      await window.__duckdb_conn.query(sql);

      const area = document.getElementById("data-load-area");
      if (area) area.style.display = "none";

      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load"; }
      showToast("Data loaded from URL", "success");

      if (window.__room_hook) {
        await window.__room_hook._executeQuery("SELECT * FROM data LIMIT 50");
      }
    } else {
      if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load"; }
      if (statusEl) statusEl.textContent = "DuckDB failed to initialize. Please reload the page.";
    }
  } catch (e) {
    if (loadBtn) { loadBtn.disabled = false; loadBtn.textContent = "Load"; }
    if (statusEl) statusEl.textContent = "Error: " + e.message;
    showToast("Failed to load: " + e.message, "error");
    console.error("Failed to load from URL:", e);
  }
}
