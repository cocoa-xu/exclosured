defmodule Kino.Exclosured do
  @moduledoc """
  A Kino widget that sends tabular data to the browser where WASM
  processes it locally. Users can compute histograms, filter rows,
  and view column statistics. All computations run client-side via
  the Exclosured WASM runtime.

  Multi-user support: filter and column selection actions are
  broadcast to all connected Livebook clients through Kino.JS.Live
  events.
  """

  use Kino.JS, assets_path: "assets"
  use Kino.JS.Live

  @doc """
  Creates a new WASM-powered data explorer widget.

  Data can be a list of maps, a list of keyword lists, or any
  enumerable of map-like rows. The data is serialized as JSON and
  sent to the browser where WASM processes it locally.

  ## Options

    * `:title` - widget title (default: "Data Explorer")
    * `:page_size` - rows per page (default: 25)

  ## Examples

      data = [
        %{name: "Alice", age: 30, salary: 75_000},
        %{name: "Bob", age: 25, salary: 62_000}
      ]

      Kino.Exclosured.new(data, title: "Employee Data")
  """
  def new(data, opts \\ []) do
    title = Keyword.get(opts, :title, "Data Explorer")
    page_size = Keyword.get(opts, :page_size, 25)

    rows = to_rows(data)

    columns =
      if rows != [] do
        rows |> hd() |> Map.keys() |> Enum.map(&to_string/1)
      else
        []
      end

    Kino.JS.Live.new(__MODULE__, %{
      rows: rows,
      columns: columns,
      title: title,
      page_size: page_size,
      active_filters: %{},
      selected_column: nil
    })
  end

  # -- Kino.JS.Live callbacks --

  @impl true
  def init(data, ctx) do
    {:ok, assign(ctx, data: data)}
  end

  @impl true
  def handle_connect(ctx) do
    data = ctx.assigns.data

    payload = %{
      rows: Jason.encode!(data.rows),
      columns: data.columns,
      title: data.title,
      page_size: data.page_size,
      active_filters: Jason.encode!(data.active_filters),
      selected_column: data.selected_column
    }

    {:ok, payload, ctx}
  end

  @impl true
  def handle_event("filter_applied", %{"column" => col, "op" => op, "value" => val}, ctx) do
    filters =
      if val == "" or val == nil do
        Map.delete(ctx.assigns.data.active_filters, col)
      else
        Map.put(ctx.assigns.data.active_filters, col, %{"op" => op, "value" => val})
      end

    ctx = update_data(ctx, :active_filters, filters)
    broadcast_event(ctx, "sync_filters", %{filters: Jason.encode!(filters)})
    {:noreply, ctx}
  end

  @impl true
  def handle_event("column_selected", %{"column" => col}, ctx) do
    ctx = update_data(ctx, :selected_column, col)
    broadcast_event(ctx, "sync_column_selected", %{column: col})
    {:noreply, ctx}
  end

  @impl true
  def handle_event("sort_applied", %{"column" => col, "direction" => dir}, ctx) do
    broadcast_event(ctx, "sync_sort", %{column: col, direction: dir})
    {:noreply, ctx}
  end

  @impl true
  def handle_event(_event, _payload, ctx) do
    {:noreply, ctx}
  end

  # -- Helpers --

  defp update_data(ctx, key, value) do
    data = Map.put(ctx.assigns.data, key, value)
    assign(ctx, data: data)
  end

  defp to_rows(data) when is_list(data) do
    Enum.map(data, fn
      row when is_map(row) -> stringify_keys(row)
      row -> row |> Map.new() |> stringify_keys()
    end)
  end

  defp to_rows(%{} = data), do: [stringify_keys(data)]

  defp to_rows(data) do
    data |> Enum.to_list() |> to_rows()
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
