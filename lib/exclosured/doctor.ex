defmodule Exclosured.Doctor do
  @moduledoc false

  @target "wasm32-unknown-unknown"

  def diagnose(opts \\ []) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    tools = tools(opts)
    config_result = Keyword.get_lazy(opts, :config, &read_config/0)
    config_check = config_check(config_result)

    tool_checks = [
      cargo_check(tools),
      rustup_target_check(tools),
      wasm_bindgen_check(tools)
    ]

    setup_checks =
      case config_result do
        {:ok, config} ->
          [
            source_dir_check(config, cwd),
            output_dir_check(config, cwd),
            optimize_check(config, tools),
            module_summary_check(config),
            module_cargo_checks(config, cwd),
            phoenix_static_check(config, cwd),
            npm_package_check(cwd)
          ]
          |> List.flatten()

        {:error, _message} ->
          []
      end

    [config_check | tool_checks ++ setup_checks]
  end

  def format_check(%{status: status, name: name, message: message}) do
    "[#{status_label(status)}] #{name}: #{message}"
  end

  def failed?(checks) do
    Enum.any?(checks, &(&1.status == :error))
  end

  def error_count(checks) do
    Enum.count(checks, &(&1.status == :error))
  end

  defp read_config do
    {:ok, Exclosured.Config.read()}
  rescue
    e in Mix.Error -> {:error, Exception.message(e)}
  end

  defp config_check({:ok, config}) do
    check(:ok, "config", "loaded Exclosured config with #{length(config.modules)} module(s)")
  end

  defp config_check({:error, message}) do
    check(:error, "config", message)
  end

  defp cargo_check(tools) do
    executable_version_check(tools, "cargo", ["--version"], "Install Rust and Cargo.")
  end

  defp rustup_target_check(tools) do
    with {:ok, rustup} <- find_tool(tools, "rustup"),
         {:ok, output} <- run_tool(tools, rustup, ["target", "list", "--installed"]) do
      if String.contains?(output, @target) do
        check(:ok, "wasm32 target", "#{@target} is installed")
      else
        check(
          :error,
          "wasm32 target",
          "#{@target} is missing; run `rustup target add #{@target}`"
        )
      end
    else
      {:missing, _tool} ->
        check(:error, "rustup", "`rustup` not found; install Rust with rustup")

      {:error, message} ->
        check(:error, "wasm32 target", message)
    end
  end

  defp wasm_bindgen_check(tools) do
    executable_version_check(
      tools,
      "wasm-bindgen",
      ["--version"],
      "Install it with `cargo install wasm-bindgen-cli`."
    )
  end

  defp executable_version_check(tools, executable, args, missing_message) do
    case find_tool(tools, executable) do
      {:ok, path} ->
        case run_tool(tools, path, args) do
          {:ok, output} -> check(:ok, executable, first_line(output))
          {:error, message} -> check(:warning, executable, message)
        end

      {:missing, _tool} ->
        check(:error, executable, "`#{executable}` not found. #{missing_message}")
    end
  end

  defp source_dir_check(config, cwd) do
    source_dir = project_path(cwd, config.source_dir)

    cond do
      File.dir?(source_dir) ->
        check(:ok, "source dir", "#{config.source_dir} exists")

      config.modules == [] ->
        check(:warning, "source dir", "#{config.source_dir} does not exist yet")

      true ->
        check(:error, "source dir", "#{config.source_dir} does not exist")
    end
  end

  defp output_dir_check(config, cwd) do
    output_dir = project_path(cwd, config.output_dir)

    if File.dir?(output_dir) do
      check(:ok, "output dir", "#{config.output_dir} exists")
    else
      check(:warning, "output dir", "#{config.output_dir} will be created during compilation")
    end
  end

  defp optimize_check(%{optimize: :none}, _tools) do
    check(:ok, "wasm-opt", "optimization is disabled")
  end

  defp optimize_check(config, tools) do
    case find_tool(tools, "wasm-opt") do
      {:ok, path} ->
        check(:ok, "wasm-opt", "found #{path} for #{config.optimize} optimization")

      {:missing, _tool} ->
        check(:warning, "wasm-opt", "not found; #{config.optimize} optimization will be skipped")
    end
  end

  defp module_summary_check(%{modules: []}) do
    check(:warning, "modules", "no WASM modules configured")
  end

  defp module_summary_check(config) do
    check(:ok, "modules", "#{length(config.modules)} module(s) configured")
  end

  defp module_cargo_checks(config, cwd) do
    Enum.map(config.modules, fn module_config ->
      name = Atom.to_string(module_config.name)
      cargo_toml = project_path(cwd, Path.join([config.source_dir, name, "Cargo.toml"]))

      if File.exists?(cargo_toml) do
        check(:ok, "module #{name}", "found Cargo.toml")
      else
        check(
          :error,
          "module #{name}",
          "missing #{Path.join([config.source_dir, name, "Cargo.toml"])}"
        )
      end
    end)
  end

  defp phoenix_static_check(config, cwd) do
    endpoint_files = Path.wildcard(Path.join([cwd, "lib", "**", "*endpoint.ex"]))
    static_segment = Path.basename(config.output_dir)

    cond do
      endpoint_files == [] ->
        check(:ok, "Phoenix static", "no endpoint files found; skipping Plug.Static check")

      Enum.any?(endpoint_files, &endpoint_serves_segment?(&1, static_segment)) ->
        check(:ok, "Phoenix static", "an endpoint appears to serve #{static_segment}")

      true ->
        check(
          :warning,
          "Phoenix static",
          "no endpoint appears to serve #{static_segment}; add it to Plug.Static :only"
        )
    end
  end

  defp endpoint_serves_segment?(file, static_segment) do
    content = File.read!(file)

    String.contains?(content, "Plug.Static") and
      (String.contains?(content, "only: :all") or
         Regex.match?(~r/\b#{Regex.escape(static_segment)}\b/, content))
  end

  defp npm_package_check(cwd) do
    package_json = Path.join([cwd, "assets", "package.json"])

    cond do
      not File.exists?(package_json) ->
        check(:ok, "npm package", "no assets/package.json found; skipping npm check")

      File.read!(package_json) =~ ~r/"exclosured"\s*:/ ->
        check(:ok, "npm package", "assets/package.json includes exclosured")

      true ->
        check(:warning, "npm package", "assets/package.json does not include exclosured")
    end
  end

  defp tools(opts) do
    %{
      find_executable: Keyword.get(opts, :find_executable, &System.find_executable/1),
      cmd: Keyword.get(opts, :cmd, &System.cmd/3)
    }
  end

  defp find_tool(%{find_executable: find_executable}, name) do
    case find_executable.(name) do
      nil -> {:missing, name}
      path -> {:ok, path}
    end
  end

  defp run_tool(%{cmd: cmd}, executable, args) do
    case cmd.(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, "#{executable} exited with #{code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp project_path(cwd, path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, cwd)
    end
  end

  defp first_line(output) do
    output
    |> String.split("\n", parts: 2)
    |> List.first()
  end

  defp check(status, name, message) do
    %{status: status, name: name, message: message}
  end

  defp status_label(:ok), do: "OK"
  defp status_label(:warning), do: "WARN"
  defp status_label(:error), do: "ERROR"
end
