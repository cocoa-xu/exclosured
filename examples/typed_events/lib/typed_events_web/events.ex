defmodule TypedEventsWeb.Events do
  @moduledoc """
  Typed event structs generated from annotated Rust structs in the
  pipeline WASM module.

  Each struct provides a `from_payload/1` function that converts a
  JSON map (with string keys) into a proper Elixir struct, enabling
  pattern matching and compile-time field access.
  """
  use Exclosured.Events, source: "native/wasm/pipeline/src/lib.rs"
end
