defmodule LiveSvelteWasmWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  @config Application.compile_env(:live_svelte_wasm, LiveSvelteWasmWeb.Endpoint)

  # `mix release` serialises the application config and rejects regexes without
  # the /E modifier, so a live_reload pattern reaching :prod breaks the release
  # build. Nothing else in the suite catches it.
  test "endpoint config carries no regexes outside :dev" do
    assert find_regex(@config) == nil
  end

  test "dev-only watchers and live_reload stay out" do
    refute Keyword.has_key?(@config, :watchers)
    refute Keyword.has_key?(@config, :live_reload)
  end

  defp find_regex(%Regex{} = regex), do: regex
  defp find_regex(%{} = map), do: map |> Map.to_list() |> find_regex()
  defp find_regex(list) when is_list(list), do: Enum.find_value(list, &find_regex/1)
  defp find_regex({_key, value}), do: find_regex(value)
  defp find_regex(_other), do: nil
end
