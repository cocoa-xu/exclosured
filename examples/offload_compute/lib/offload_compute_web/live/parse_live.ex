defmodule OffloadComputeWeb.ParseLive do
  use Phoenix.LiveView

  @sample_csv """
  name,age,salary,rating
  Alice Johnson,32,75000,4.5
  Bob Smith,28,62000,3.8
  Carol White,45,95000,4.9
  David Brown,38,84000,4.2
  Eva Martinez,29,58000,3.6
  Frank Lee,52,110000,4.7
  Grace Kim,34,72000,4.1
  Henry Davis,41,89000,4.4
  Iris Wilson,26,54000,3.9
  Jack Taylor,47,98000,4.6
  Karen Moore,33,71000,4.0
  Leo Anderson,39,82000,4.3
  Mia Thomas,31,67000,3.7
  Noah Jackson,44,93000,4.8
  Olivia Harris,27,56000,3.5
  Paul Martin,50,105000,4.6
  Quinn Garcia,36,78000,4.2
  Rachel Clark,30,64000,3.9
  Sam Rodriguez,43,91000,4.5
  Tina Lewis,35,76000,4.1
  Uma Walker,48,99000,4.7
  Victor Hall,29,59000,3.8
  Wendy Allen,42,88000,4.4
  Xavier Young,37,80000,4.0
  Yara King,46,97000,4.6
  Zane Wright,33,70000,3.9
  Amy Scott,40,86000,4.3
  Brian Green,28,57000,3.6
  Chloe Adams,51,108000,4.8
  Derek Baker,34,73000,4.1
  Elena Nelson,38,83000,4.2
  Felix Hill,45,94000,4.5
  Gina Rivera,30,65000,3.7
  Hugo Campbell,42,87000,4.4
  Isla Mitchell,27,55000,3.5
  Jake Roberts,49,101000,4.7
  Kara Turner,36,77000,4.0
  Liam Phillips,32,69000,3.8
  Maya Evans,44,92000,4.6
  Nate Edwards,39,81000,4.3
  Opal Collins,31,66000,3.9
  Pete Stewart,47,96000,4.5
  Rosa Sanchez,35,74000,4.1
  Sean Morris,41,85000,4.2
  Tara Rogers,29,60000,3.7
  Ulric Reed,53,112000,4.9
  Vera Cook,37,79000,4.0
  Wade Morgan,43,90000,4.4
  Xena Bell,26,53000,3.4
  Yuri Murphy,48,100000,4.7\
  """

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       csv_data: @sample_csv,
       server_result: nil,
       server_time_us: nil,
       wasm_result: nil,
       wasm_time_ms: nil,
       wasm_ready: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Offload Computation</h1>
    <p class="desc">
      Compare CSV parsing on the server (Elixir) vs. client-side (WASM).
      Edit the data below, then click either button to parse.
    </p>

    <div id="wasm-loader" phx-hook="ExclosuredHook"></div>

    <form phx-change="update_data" phx-submit="parse_server">
      <textarea name="csv_data" id="csv-input"><%= @csv_data %></textarea>

      <div class="btn-row">
        <button type="submit" class="btn-server">
          Parse on Server
        </button>
        <button type="button" class="btn-wasm" id="wasm-parse-btn"
                phx-hook="WasmParseHook" disabled={!@wasm_ready}>
          <%= if @wasm_ready, do: "Parse in WASM", else: "Loading WASM..." %>
        </button>
      </div>
    </form>

    <div class="results">
      <div class="panel panel-server">
        <h3>Server (Elixir)</h3>
        <%= if @server_time_us do %>
          <div class="timing"><%= @server_time_us %> us</div>
        <% end %>
        <%= if @server_result do %>
          <pre><%= @server_result %></pre>
        <% else %>
          <pre style="color:#666;">Click "Parse on Server" to see results</pre>
        <% end %>
      </div>

      <div class="panel panel-wasm">
        <h3>Client (WASM)</h3>
        <%= if @wasm_time_ms do %>
          <div class="timing"><%= @wasm_time_ms %> ms</div>
        <% end %>
        <%= if @wasm_result do %>
          <pre><%= @wasm_result %></pre>
        <% else %>
          <pre style="color:#666;">Click "Parse in WASM" to see results</pre>
        <% end %>
      </div>
    </div>

    <p :if={!@wasm_ready} class="status">Loading WASM module...</p>
    """
  end

  @impl true
  def handle_event("update_data", %{"csv_data" => csv_data}, socket) do
    {:noreply, assign(socket, csv_data: csv_data)}
  end

  def handle_event("parse_server", %{"csv_data" => csv_data}, socket) do
    {time_us, result} = :timer.tc(fn -> parse_csv_elixir(csv_data) end)
    json = Jason.encode!(result, pretty: true)

    {:noreply,
     assign(socket,
       csv_data: csv_data,
       server_result: json,
       server_time_us: time_us
     )}
  end

  def handle_event("wasm:ready", _params, socket) do
    {:noreply, assign(socket, wasm_ready: true)}
  end

  def handle_event("wasm_parse_result", %{"result" => result, "time_ms" => time_ms}, socket) do
    # Pretty-print the JSON result
    formatted =
      case Jason.decode(result) do
        {:ok, parsed} -> Jason.encode!(parsed, pretty: true)
        _ -> result
      end

    {:noreply, assign(socket, wasm_result: formatted, wasm_time_ms: time_ms)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  # Server-side CSV parsing in pure Elixir
  defp parse_csv_elixir(csv_text) do
    lines =
      csv_text
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] ->
        %{rows: 0, columns: 0, numeric_values: 0, min: 0.0, max: 0.0, avg: 0.0}

      [header | data_lines] ->
        columns =
          header
          |> String.split(",")
          |> length()

        rows = length(data_lines)

        # Collect all numeric values from data rows
        numerics =
          data_lines
          |> Enum.flat_map(fn line ->
            line
            |> String.split(",")
            |> Enum.flat_map(fn field ->
              trimmed = String.trim(field)

              case Float.parse(trimmed) do
                {val, ""} -> [val]
                _ ->
                  case Integer.parse(trimmed) do
                    {val, ""} -> [val * 1.0]
                    _ -> []
                  end
              end
            end)
          end)

        numeric_count = length(numerics)

        if numeric_count > 0 do
          min_val = Enum.min(numerics)
          max_val = Enum.max(numerics)
          avg_val = Float.round(Enum.sum(numerics) / numeric_count, 2)

          %{
            rows: rows,
            columns: columns,
            numeric_values: numeric_count,
            min: min_val,
            max: max_val,
            avg: avg_val
          }
        else
          %{rows: rows, columns: columns, numeric_values: 0, min: 0.0, max: 0.0, avg: 0.0}
        end
    end
  end
end
