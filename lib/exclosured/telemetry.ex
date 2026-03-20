defmodule Exclosured.Telemetry do
  @moduledoc """
  Telemetry events emitted by Exclosured.

  Attach handlers to observe WASM compilation, function calls, and events.
  All events follow the `:telemetry.execute/3` convention.

  ## Events

  ### `[:exclosured, :compile, :start]`

  Emitted when a WASM module starts compiling.

    * Measurement: `%{system_time: integer}`
    * Metadata: `%{module: atom}`

  ### `[:exclosured, :compile, :stop]`

  Emitted when a WASM module finishes compiling.

    * Measurement: `%{duration: integer}` (native time units)
    * Metadata: `%{module: atom, wasm_size: integer | nil}`

  ### `[:exclosured, :compile, :error]`

  Emitted when a WASM module fails to compile.

    * Measurement: `%{duration: integer}`
    * Metadata: `%{module: atom, error: String.t()}`

  ### `[:exclosured, :wasm, :call]`

  Emitted when a WASM function is called via LiveView.

    * Measurement: `%{}`
    * Metadata: `%{module: atom, func: String.t()}`

  ### `[:exclosured, :wasm, :result]`

  Emitted when a WASM function returns a result.

    * Measurement: `%{}`
    * Metadata: `%{module: atom, func: String.t()}`

  ### `[:exclosured, :wasm, :emit]`

  Emitted when WASM sends an event to LiveView.

    * Measurement: `%{}`
    * Metadata: `%{module: atom, event: String.t()}`

  ### `[:exclosured, :wasm, :error]`

  Emitted when a WASM function call fails.

    * Measurement: `%{}`
    * Metadata: `%{module: atom, func: String.t(), error: String.t()}`

  ### `[:exclosured, :wasm, :ready]`

  Emitted when a WASM module finishes loading in the browser.

    * Measurement: `%{}`
    * Metadata: `%{module: atom}`

  ## Example: Logging Handler

      :telemetry.attach_many(
        "exclosured-logger",
        [
          [:exclosured, :compile, :stop],
          [:exclosured, :wasm, :call],
          [:exclosured, :wasm, :emit],
          [:exclosured, :wasm, :error]
        ],
        fn event, measurements, metadata, _config ->
          IO.inspect({event, measurements, metadata}, label: "exclosured")
        end,
        nil
      )
  """

  @doc false
  def compile_start(module) do
    :telemetry.execute(
      [:exclosured, :compile, :start],
      %{system_time: System.system_time()},
      %{module: module}
    )
  end

  @doc false
  def compile_stop(module, start_time, opts \\ []) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:exclosured, :compile, :stop],
      %{duration: duration},
      %{module: module, wasm_size: opts[:wasm_size]}
    )
  end

  @doc false
  def compile_error(module, start_time, error) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:exclosured, :compile, :error],
      %{duration: duration},
      %{module: module, error: error}
    )
  end

  @doc false
  def wasm_call(module, func) do
    :telemetry.execute(
      [:exclosured, :wasm, :call],
      %{},
      %{module: module, func: func}
    )
  end

  @doc false
  def wasm_result(module, func) do
    :telemetry.execute(
      [:exclosured, :wasm, :result],
      %{},
      %{module: module, func: func}
    )
  end

  @doc false
  def wasm_emit(module, event) do
    :telemetry.execute(
      [:exclosured, :wasm, :emit],
      %{},
      %{module: module, event: event}
    )
  end

  @doc false
  def wasm_error(module, func, error) do
    :telemetry.execute(
      [:exclosured, :wasm, :error],
      %{},
      %{module: module, func: func, error: error}
    )
  end

  @doc false
  def wasm_ready(module) do
    :telemetry.execute(
      [:exclosured, :wasm, :ready],
      %{},
      %{module: module}
    )
  end
end
