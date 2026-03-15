defmodule Exclosured.Watcher do
  @moduledoc """
  File watcher for development. Triggers WASM recompilation when
  Rust source files change.

  ## Usage

  Add to your Phoenix endpoint configuration:

      config :my_app, MyAppWeb.Endpoint,
        watchers: [
          exclosured: {Exclosured.Watcher, :watch, []}
        ]

  Phoenix LiveReload will detect changes in `priv/static/wasm/`
  and automatically refresh the browser.
  """

  use GenServer

  require Logger

  @poll_interval 1_000

  @doc """
  Starts the watcher. Called by Phoenix endpoint watcher config.
  """
  def watch do
    {:ok, pid} = GenServer.start_link(__MODULE__, [], name: __MODULE__)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    config = Exclosured.Config.read()

    state = %{
      config: config,
      last_mtimes: collect_all_mtimes(config)
    }

    if Code.ensure_loaded?(FileSystem) do
      {:ok, watcher_pid} = apply(FileSystem, :start_link, [[dirs: [config.source_dir]]])
      apply(FileSystem, :subscribe, [watcher_pid])
      {:ok, Map.put(state, :watcher_pid, watcher_pid)}
    else
      schedule_poll()
      {:ok, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if should_recompile?(path) do
      recompile(state.config)
    end

    {:noreply, state}
  end

  def handle_info(:poll, state) do
    current_mtimes = collect_all_mtimes(state.config)

    if current_mtimes != state.last_mtimes do
      recompile(state.config)
    end

    schedule_poll()
    {:noreply, %{state | last_mtimes: current_mtimes}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp should_recompile?(path) do
    ext = Path.extname(path)
    ext in [".rs", ".toml"]
  end

  defp recompile(config) do
    Logger.info("Exclosured: source change detected, recompiling...")

    stale = Exclosured.Manifest.stale_modules(config)
    manifest = Exclosured.Manifest.read()

    manifest =
      Enum.reduce(stale, manifest, fn mod, manifest ->
        case Exclosured.Compiler.compile_module(mod, config) do
          :ok ->
            Exclosured.Manifest.update_module(manifest, mod, config)

          {:error, message} ->
            Logger.error("Exclosured: #{message}")
            manifest
        end
      end)

    Exclosured.Manifest.write(manifest)
  end

  defp collect_all_mtimes(config) do
    config.source_dir
    |> Path.join("**/*.{rs,toml}")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %{mtime: mtime}} -> {file, mtime}
        _ -> {file, 0}
      end
    end)
    |> Map.new()
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
