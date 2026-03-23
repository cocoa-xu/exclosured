defmodule LiveSvelteWasmWeb.CollabLive do
  use Phoenix.LiveView
  import LiveSvelte

  alias LiveSvelteWasm.CollabRoom

  @impl true
  def mount(%{"room" => room_id}, _session, socket) do
    client_id = generate_client_id()

    if connected?(socket) do
      {:ok, doc, version} = CollabRoom.join(room_id)
      Phoenix.PubSub.subscribe(LiveSvelteWasm.PubSub, "collab:#{room_id}")

      {:ok,
       assign(socket,
         room_id: room_id,
         client_id: client_id,
         doc: doc,
         version: version,
         wasm_ready: false
       )}
    else
      {:ok,
       assign(socket,
         room_id: room_id,
         client_id: client_id,
         doc: "",
         version: 0,
         wasm_ready: false
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.svelte
      name="CollabEditor"
      props={%{
        initial_doc: @doc,
        initial_version: @version,
        client_id: @client_id,
        room_id: @room_id
      }}
      ssr={false}
    />
    """
  end

  @impl true
  def handle_event("submit_op", %{"op" => op, "version" => base_version}, socket) do
    op = decode_op(op)

    case CollabRoom.submit_op(
           socket.assigns.room_id,
           socket.assigns.client_id,
           base_version,
           op
         ) do
      {:ok, new_version} ->
        {:noreply, push_event(socket, "ot:ack", %{version: new_version})}

      {:error, _reason, doc, version} ->
        {:noreply, push_event(socket, "ot:resync", %{doc: doc, version: version})}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:remote_op, version, author_client_id, op}, socket) do
    if author_client_id != socket.assigns.client_id do
      {:noreply,
       push_event(socket, "ot:remote_op", %{
         version: version,
         op: encode_op(op)
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if Map.has_key?(socket.assigns, :room_id) do
      CollabRoom.leave(socket.assigns.room_id)
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp generate_client_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # JSON-safe encoding: ops are already [int | string] which Jason handles fine
  defp encode_op(op), do: op

  defp decode_op(op) when is_list(op) do
    Enum.map(op, fn
      n when is_integer(n) -> n
      s when is_binary(s) -> s
      n when is_float(n) -> trunc(n)
    end)
  end
end
