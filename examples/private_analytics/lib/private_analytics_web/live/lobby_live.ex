defmodule PrivateAnalyticsWeb.LobbyLive do
  use Phoenix.LiveView, layout: {PrivateAnalyticsWeb.Layouts, :app}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, join_value: "", join_error: nil)}
  end

  @impl true
  def handle_event("create_room", _params, socket) do
    room_id = generate_room_id()
    {:noreply, push_navigate(socket, to: "/room/#{room_id}")}
  end

  @impl true
  def handle_event("update_join", %{"value" => value}, socket) do
    {:noreply, assign(socket, join_value: value, join_error: nil)}
  end

  @impl true
  def handle_event("join_room", %{"room_input" => input}, socket) do
    room_id = extract_room_id(input)

    if room_id != "" do
      {:noreply, push_navigate(socket, to: "/room/#{room_id}")}
    else
      {:noreply, assign(socket, join_error: "Please enter a valid room ID or URL.")}
    end
  end

  defp generate_room_id do
    :crypto.strong_rand_bytes(6)
    |> Base.url_encode64(padding: false)
  end

  defp extract_room_id(input) do
    input = String.trim(input)

    cond do
      # Full URL with /room/ path
      String.contains?(input, "/room/") ->
        input
        |> String.split("/room/")
        |> List.last()
        |> String.split("#")
        |> List.first()
        |> String.split("?")
        |> List.first()
        |> String.trim()

      # Plain room ID
      String.match?(input, ~r/^[a-zA-Z0-9_\-]+$/) ->
        input

      true ->
        ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lobby">
      <div class="lobby-title">
        <h1>Private Analytics</h1>
        <p>
          Create a private data analytics room. Load CSV data into DuckDB-WASM
          in your browser. Share encrypted views with collaborators. All data
          stays end-to-end encrypted; the server only relays opaque blobs.
        </p>
      </div>

      <div class="lobby-actions">
        <button class="btn btn-primary" phx-click="create_room">
          Create New Room
        </button>

        <div class="lobby-divider">or join an existing room</div>

        <form phx-submit="join_room">
          <div class="join-form">
            <input
              type="text"
              name="room_input"
              value={@join_value}
              placeholder="Paste room URL or ID"
              phx-keyup="update_join"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-secondary">Join</button>
          </div>
        </form>

        <p :if={@join_error} class="error-bar"><%= @join_error %></p>
      </div>
    </div>
    """
  end
end
