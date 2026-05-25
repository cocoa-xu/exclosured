defmodule Exclosured.RPC.Parser do
  @moduledoc """
  Parses Rust source files for `/// exclosured:rpc` annotated functions.
  """

  @doc """
  Parse a Rust source string and return annotated RPC exports.

  Each RPC is a map:

      %{
        name: "score",
        args: [%{name: "input", type: "String"}],
        return: "u32",
        async: false
      }
  """
  def parse(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> scan_lines([])
    |> Enum.reverse()
  end

  defp scan_lines([], acc), do: acc

  defp scan_lines([line | rest], acc) do
    trimmed = String.trim(line)

    if String.contains?(trimmed, "exclosured:rpc") do
      {signature, remaining} = find_function_signature(rest)

      case signature && parse_signature(signature) do
        {:ok, rpc} -> scan_lines(remaining, [rpc | acc])
        _other -> scan_lines(remaining, acc)
      end
    else
      scan_lines(rest, acc)
    end
  end

  defp find_function_signature([]), do: {nil, []}

  defp find_function_signature([line | rest] = lines) do
    trimmed = String.trim(line)

    cond do
      skippable_line?(trimmed) ->
        find_function_signature(rest)

      function_line?(trimmed) ->
        collect_signature([line], rest)

      true ->
        {nil, lines}
    end
  end

  defp skippable_line?(line) do
    line == "" or String.starts_with?(line, "//") or String.starts_with?(line, "#[")
  end

  defp function_line?(line) do
    Regex.match?(~r/\bfn\s+[A-Za-z_][A-Za-z0-9_]*/, line)
  end

  defp collect_signature(lines, rest) do
    signature =
      lines
      |> Enum.reverse()
      |> Enum.map(&String.trim/1)
      |> Enum.join(" ")

    if signature_complete?(signature) do
      {signature, rest}
    else
      case rest do
        [] -> {signature, []}
        [line | rest] -> collect_signature([line | lines], rest)
      end
    end
  end

  defp signature_complete?(signature) do
    String.contains?(signature, "{") or String.ends_with?(signature, ";")
  end

  defp parse_signature(signature) do
    signature =
      signature
      |> strip_after("{")
      |> strip_after(";")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    captures =
      Regex.named_captures(
        ~r/^(?:pub(?:\([^)]*\))?\s+)?(?<async>async\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]+"\s+)?fn\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\((?<args>.*)\)\s*(?:->\s*(?<return>.+))?$/,
        signature
      )

    case captures do
      %{"name" => name, "args" => args} = captures ->
        {:ok,
         %{
           name: name,
           args: parse_args(args),
           return: normalize_return(captures["return"]),
           async: captures["async"] != ""
         }}

      nil ->
        :error
    end
  end

  defp strip_after(value, delimiter) do
    value
    |> String.split(delimiter, parts: 2)
    |> hd()
  end

  defp normalize_return(nil), do: nil
  defp normalize_return(""), do: nil

  defp normalize_return(return_type) do
    return_type
    |> String.replace(~r/\s+where\s+.+$/, "")
    |> String.trim()
  end

  defp parse_args(args) do
    args
    |> split_top_level_commas()
    |> Enum.map(&parse_arg/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_arg(arg) do
    arg = String.trim(arg)

    case Regex.run(~r/^(?:mut\s+)?(?:r#)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/, arg) do
      [_, name, type] -> %{name: name, type: String.trim(type)}
      _other -> nil
    end
  end

  defp split_top_level_commas(value) do
    value
    |> String.graphemes()
    |> split_top_level_commas([], "", {0, 0, 0})
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_top_level_commas([], parts, current, _depth) do
    Enum.reverse([current | parts])
  end

  defp split_top_level_commas(["," | rest], parts, current, {0, 0, 0}) do
    split_top_level_commas(rest, [current | parts], "", {0, 0, 0})
  end

  defp split_top_level_commas([char | rest], parts, current, depth) do
    split_top_level_commas(rest, parts, current <> char, update_depth(char, depth))
  end

  defp update_depth("<", {angle, paren, bracket}), do: {angle + 1, paren, bracket}
  defp update_depth(">", {angle, paren, bracket}) when angle > 0, do: {angle - 1, paren, bracket}
  defp update_depth("(", {angle, paren, bracket}), do: {angle, paren + 1, bracket}
  defp update_depth(")", {angle, paren, bracket}) when paren > 0, do: {angle, paren - 1, bracket}
  defp update_depth("[", {angle, paren, bracket}), do: {angle, paren, bracket + 1}

  defp update_depth("]", {angle, paren, bracket}) when bracket > 0,
    do: {angle, paren, bracket - 1}

  defp update_depth(_char, depth), do: depth
end
