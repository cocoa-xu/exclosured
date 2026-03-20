defmodule Exclosured.Events.Parser do
  @moduledoc """
  Parses Rust source files for `/// exclosured:event` annotated structs.

  Extracts struct names and field definitions for codegen.
  """

  @doc """
  Parse a Rust source string and return a list of event structs.

  Each event is a map:

      %{name: "ProgressEvent", fields: [%{name: "percent", type: "u32"}, ...]}
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

    if String.contains?(trimmed, "exclosured:event") do
      # Next non-empty, non-comment line should be the struct definition
      {struct_def, remaining} = find_struct_line(rest)

      case struct_def do
        nil ->
          scan_lines(rest, acc)

        struct_line ->
          case parse_struct_header(struct_line) do
            {:ok, name} ->
              {fields, remaining} = parse_fields(remaining, [])
              event = %{name: name, fields: fields}
              scan_lines(remaining, [event | acc])

            :error ->
              scan_lines(remaining, acc)
          end
      end
    else
      scan_lines(rest, acc)
    end
  end

  defp find_struct_line([]), do: {nil, []}

  defp find_struct_line([line | rest] = lines) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "//") or String.starts_with?(trimmed, "#[") ->
        find_struct_line(rest)

      String.contains?(trimmed, "struct") ->
        {trimmed, rest}

      true ->
        {nil, lines}
    end
  end

  defp parse_struct_header(line) do
    case Regex.run(~r/(?:pub\s+)?struct\s+(\w+)/, line) do
      [_, name] -> {:ok, name}
      _ -> :error
    end
  end

  defp parse_fields([], acc), do: {Enum.reverse(acc), []}

  defp parse_fields([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "}" or String.starts_with?(trimmed, "}") ->
        {Enum.reverse(acc), rest}

      String.contains?(trimmed, ":") ->
        case parse_field(trimmed) do
          {:ok, field} -> parse_fields(rest, [field | acc])
          :skip -> parse_fields(rest, acc)
        end

      true ->
        parse_fields(rest, acc)
    end
  end

  defp parse_field(line) do
    # Match: pub field_name: Type, or field_name: Type,
    case Regex.run(~r/(?:pub\s+)?(\w+)\s*:\s*([^,]+)/, line) do
      [_, name, type] ->
        type = type |> String.trim() |> String.trim_trailing(",")
        {:ok, %{name: name, type: type}}

      _ ->
        :skip
    end
  end
end
