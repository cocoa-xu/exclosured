defmodule Exclosured.Manifest do
  @moduledoc """
  Manages the build manifest for incremental compilation.

  Tracks modification times of source files (.rs, .toml) to determine
  which modules need recompilation.
  """

  @manifest_filename "exclosured.manifest"

  @doc """
  Returns the path to the manifest file.
  """
  def path do
    Path.join(Mix.Project.manifest_path(), @manifest_filename)
  end

  @doc """
  Reads the manifest from disk. Returns an empty map if not found.
  """
  def read do
    case File.read(path()) do
      {:ok, content} ->
        content
        |> :erlang.binary_to_term()
        |> migrate()

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Writes the manifest to disk.
  """
  def write(manifest) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), :erlang.term_to_binary(manifest))
  end

  @doc """
  Deletes the manifest file.
  """
  def clean do
    File.rm(path())
  end

  @doc """
  Returns the list of modules that need recompilation based on
  changed source files.
  """
  def stale_modules(config) do
    manifest = read()

    config
    |> Exclosured.Config.compilable_modules()
    |> Enum.filter(fn mod ->
      module_stale?(mod, config, manifest)
    end)
  end

  @doc """
  Updates the manifest entry for a compiled module by recording
  current mtimes of its source files.
  """
  def update_module(manifest, module_config, config) do
    name = Atom.to_string(module_config.name)
    source_dir = Path.join(config.source_dir, name)
    mtimes = collect_mtimes(source_dir)
    Map.put(manifest, module_config.name, %{mtimes: mtimes})
  end

  defp module_stale?(module_config, config, manifest) do
    name = Atom.to_string(module_config.name)
    source_dir = Path.join(config.source_dir, name)

    case Map.get(manifest, module_config.name) do
      nil ->
        true

      %{mtimes: old_mtimes} ->
        current_mtimes = collect_mtimes(source_dir)
        current_mtimes != old_mtimes
    end
  end

  defp collect_mtimes(dir) do
    if File.dir?(dir) do
      dir
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
    else
      %{}
    end
  end

  defp migrate(manifest) when is_map(manifest), do: manifest
  defp migrate(_), do: %{}
end
