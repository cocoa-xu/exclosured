# Kino Exclosured

A custom Kino widget that brings WASM-powered data exploration to
[Livebook](https://livebook.dev). It takes data from Elixir, sends
it to the browser, and uses an Exclosured WASM module to compute
histograms, column statistics, and filters entirely client-side.

Multiple Livebook users see synced interactions (filters, column
selection, sorting) via Kino.JS.Live event broadcasting.

## Prerequisites

- Rust toolchain with `wasm32-unknown-unknown` target
- `wasm-bindgen-cli`: `cargo install wasm-bindgen-cli`

**Important: Livebook cannot find `cargo` by default.** Livebook runs
as a standalone application and does not inherit your shell's `PATH`.
You must configure the `PATH` environment variable in Livebook before
opening the notebook:

1. Go to Livebook Settings > Environment variables
   (or visit `http://localhost:<port>/settings/env-var/new`)
2. Add a variable named `PATH` with a value like:

   ```
   /Users/<your-username>/.cargo/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
   ```

   On macOS with Homebrew, this covers both Rust (`~/.cargo/bin`) and
   system tools. Adjust the path to `~/.cargo/bin` for your username.

3. Restart the Livebook runtime (or reconnect) for the change to take
   effect.

## Architecture

```
Elixir (Kino.JS.Live)         Browser (Kino.JS)
 +---------------------+       +-------------------------+
 | Kino.Exclosured.new |  -->  | main.js init()          |
 | - serialize as JSON |       | - render table + UI     |
 | - handle_connect    |       | - load WASM module      |
 | - broadcast events  |       | - compute stats in WASM |
 +---------------------+       +-------------------------+
```

- **Elixir side**: `Kino.Exclosured.new(data, opts)` creates the
  widget. Data is serialized as JSON and sent to each connecting
  client via `handle_connect/1`.
- **Browser side**: `assets/main.js` renders the data table,
  histogram, and statistics panel. Statistics and histograms are
  computed in WebAssembly.
- **Multi-user sync**: filter, sort, and column selection events
  are pushed to the server via `pushEvent`, then broadcast to
  all connected clients via `broadcast_event`.
- **WASM module**: `KinoExclosured.Stats` uses `Exclosured.Inline`
  to define `compute_stats` and `compute_histogram` in Rust,
  compiled to `.wasm` at build time.

## Usage in Livebook

Open `notebook.livemd` from this directory in Livebook. The setup
cell uses `path: __DIR__` to locate the package, so the notebook
file must be saved in the `examples/kino_exclosured/` directory.

Alternatively, use an absolute path in a new notebook:

```elixir
Mix.install([
  {:kino_exclosured, path: "/path/to/examples/kino_exclosured"},
  {:kino, "~> 0.14"},
  {:jason, "~> 1.0"}
])
```

Then in a code cell:

```elixir
data = [
  %{name: "Alice", age: 30, salary: 75_000, department: "Engineering"},
  %{name: "Bob", age: 25, salary: 62_000, department: "Marketing"}
]

Kino.Exclosured.new(data, title: "Employee Data", page_size: 5)
```

## Features

- **Column statistics**: select a numeric column to see count, min,
  max, mean, median, standard deviation, P25, and P75
- **Histogram**: visual bar chart of value distribution (20 bins)
- **Filtering**: per-column filters with operators (contains, =, >, <)
- **Sorting**: click column headers to sort ascending/descending
- **Pagination**: navigate large datasets page by page
- **Multi-user sync**: all connected Livebook users see the same
  filter, sort, and analysis state
