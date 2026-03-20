# Sync Demo: Declarative State Sync

This demo shows how the `sync` attribute on `Exclosured.LiveView.sandbox`
enables automatic state flow from LiveView assigns to WASM modules.

## The Problem

Without `sync`, every event handler that updates state must also manually push
that state to the WASM module:

```elixir
# Before: manual push_event in every handler
def handle_event("update", %{"speed" => speed}, socket) do
  socket =
    socket
    |> assign(speed: String.to_integer(speed))
    |> push_event("wasm:state", %{speed: String.to_integer(speed)})

  {:noreply, socket}
end
```

## The Solution

With `sync`, you just assign and the component handles the rest:

```elixir
# After: just assign, sync handles delivery
def handle_event("update", %{"speed" => speed}, socket) do
  {:noreply, assign(socket, speed: String.to_integer(speed))}
end
```

The sandbox component declares which assigns to sync:

```heex
<Exclosured.LiveView.sandbox
  module={:visualizer}
  sync={%{
    frequency: @frequency,
    amplitude: @amplitude,
    speed: @speed,
    color: @color,
    wave_type: @wave_type
  }}
  canvas
  width={600}
  height={300}
/>
```

When LiveView re-renders and the sync map has changed, the hook's `updated()`
callback detects the change and pushes the new state to the WASM module
automatically. No `push_event` calls needed.

## Running

```bash
mix deps.get
mix run --no-halt
# Visit http://localhost:4008
```
