defmodule LiveSvelteWasmWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LiveSvelteWasmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", LiveSvelteWasmWeb do
    pipe_through :browser
    live "/", EditorLive
    live "/collab/:room", CollabLive
  end
end
