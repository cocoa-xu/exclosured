# Typed Events Demo

This demo showcases `use Exclosured.Events`, which generates Elixir structs
from annotated Rust structs. The result is type-safe event handling between
WASM modules and LiveView.

## The Pattern

1. Annotate Rust structs with `/// exclosured:event`
2. Use `Exclosured.Events` in your Elixir module, pointing at the Rust source
3. Get auto-generated Elixir structs with `from_payload/1` for converting
   JSON maps into proper structs

## Rust Side

```rust
/// exclosured:event
pub struct StageComplete {
    pub stage_name: String,
    pub items_processed: u32,
    pub duration_ms: u32,
}

// Emit as JSON:
exclosured_guest::emit("stage_complete", &payload);
```

## Elixir Side

```elixir
defmodule TypedEventsWeb.Events do
  use Exclosured.Events,
    source: "native/wasm/pipeline/src/lib.rs"
end
```

This generates `TypedEventsWeb.Events.StageComplete` with:
- `defstruct [:stage_name, :items_processed, :duration_ms]`
- `@type t` with proper typespecs (`String.t()`, `integer()`, etc.)
- `from_payload/1` to convert JSON maps into the struct

## Before vs After

**Before** (raw maps, no compile-time checking):

```elixir
def handle_info({:wasm_emit, :pipeline, "stage_complete", payload}, socket) do
  name = payload["stage_name"]       # string key lookup, no guarantees
  count = payload["items_procesed"]  # typo => silent nil
  {:noreply, assign(socket, stage: name, count: count)}
end
```

**After** (typed structs, compile-time field access):

```elixir
def handle_info({:wasm_emit, :pipeline, "stage_complete", payload}, socket) do
  event = Events.StageComplete.from_payload(payload)
  event.stage_name       # String.t(), known at compile time
  event.items_processed  # integer(), typo would be a compile error
  {:noreply, assign(socket, stage: event.stage_name, count: event.items_processed)}
end
```

## The Demo

A WASM module simulates a data processing pipeline that emits four typed
events as it processes items through three stages (parse, validate, transform):

- `PipelineStarted` (total_items, stages)
- `StageComplete` (stage_name, items_processed, duration_ms)
- `ItemProcessed` (item_id, stage_name, result)
- `PipelineFinished` (total_processed, total_duration_ms, success_rate)

The LiveView uses `from_payload/1` to convert each JSON payload into its
corresponding struct, then pattern-matches on the typed fields to update
the dashboard.

## Running

```bash
cd examples/typed_events
mix deps.get
mix phx.server
```

Open http://localhost:4010 in your browser.

Note: the WASM module must be compiled first. The exclosured compiler
handles this automatically when you run `mix phx.server`.
