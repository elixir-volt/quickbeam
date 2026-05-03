defmodule QuickBEAM.JS.Parser.Lexer.Regexp.Groups do
  @moduledoc "Named capture group and backreference validation."

  def regexp_named_group_error(pattern, flags) do
    case collect_regexp_group_names(pattern, 0, []) do
      {:error, error} ->
        error

      {:ok, []} ->
        if binary_part?(flags, "u") or binary_part?(flags, "v") do
          regexp_backreference_error(pattern, 0, MapSet.new())
        end

      {:ok, names} ->
        regexp_backreference_error(pattern, 0, MapSet.new(names))
    end
  end

  defp collect_regexp_group_names(pattern, offset, names) when offset >= byte_size(pattern),
    do: {:ok, Enum.reverse(names)}

  defp collect_regexp_group_names(pattern, offset, names) do
    case :binary.match(pattern, "(?<", scope: {offset, byte_size(pattern) - offset}) do
      :nomatch ->
        {:ok, Enum.reverse(names)}

      {index, 3} ->
        name_start = index + 3

        if name_start < byte_size(pattern) and :binary.at(pattern, name_start) in [?=, ?!] do
          collect_regexp_group_names(pattern, name_start + 1, names)
        else
          case read_regexp_group_name(pattern, name_start) do
            {:ok, name, next_offset} ->
              cond do
                not valid_regexp_group_name?(name) -> {:error, "invalid group name"}
                name in names -> {:error, "duplicate group name"}
                true -> collect_regexp_group_names(pattern, next_offset, [name | names])
              end

            :error ->
              {:error, "invalid group name"}
          end
        end
    end
  end

  defp read_regexp_group_name(pattern, index), do: read_regexp_group_name(pattern, index, [])

  defp read_regexp_group_name(pattern, index, _acc) when index >= byte_size(pattern), do: :error

  defp read_regexp_group_name(pattern, index, acc) do
    ch = :binary.at(pattern, index)

    cond do
      ch == ?> -> {:ok, IO.iodata_to_binary(Enum.reverse(acc)), index + 1}
      ch in [?/, ?), ?(, ?|] -> :error
      true -> read_regexp_group_name(pattern, index + 1, [ch | acc])
    end
  end

  defp valid_regexp_group_name?(""), do: false

  defp valid_regexp_group_name?(name) do
    case String.graphemes(name) do
      [first | rest] ->
        not invalid_regexp_group_name_escape?(name) and regexp_group_name_start?(first) and
          Enum.all?(rest, &regexp_group_name_part?/1)

      [] ->
        false
    end
  end

  defp invalid_regexp_group_name_escape?(name) do
    Regex.match?(~r/\\(?!u(?:[0-9A-Fa-f]{4}|\{[0-9A-Fa-f]+\}))/, name) or
      invalid_regexp_group_surrogate_escape?(name) or
      Regex.match?(~r/\\u\{(?:1F[0-9A-Fa-f]+|10FFFF)\}/, name)
  end

  defp invalid_regexp_group_surrogate_escape?(name) do
    Regex.scan(~r/\\uD[89A-Fa-f][0-9A-Fa-f]{2}/, name, return: :index)
    |> Enum.any?(fn [{index, length} | _captures] ->
      escape = binary_part(name, index, length)
      lead? = Regex.match?(~r/^\\uD[89AB][0-9A-Fa-f]{2}$/i, escape)
      trail? = Regex.match?(~r/^\\uD[CDEF][0-9A-Fa-f]{2}$/i, escape)

      next_escape =
        binary_part(
          name,
          min(index + length, byte_size(name)),
          byte_size(name) - min(index + length, byte_size(name))
        )

      previous_offset = max(index - 6, 0)
      previous_escape = binary_part(name, previous_offset, index - previous_offset)

      cond do
        trail? and not Regex.match?(~r/\\uD[89AB][0-9A-Fa-f]{2}$/i, previous_escape) ->
          true

        lead? and not Regex.match?(~r/^\\uD[CDEF][0-9A-Fa-f]{2}/i, next_escape) ->
          true

        lead? ->
          invalid_regexp_group_surrogate_pair?(escape, next_escape)

        true ->
          false
      end
    end)
  end

  defp invalid_regexp_group_surrogate_pair?(lead_escape, next_escape) do
    <<"\\u", lead_hex::binary-size(4)>> = lead_escape
    <<"\\u", trail_hex::binary-size(4), _rest::binary>> = next_escape
    {lead, ""} = Integer.parse(lead_hex, 16)
    {trail, ""} = Integer.parse(trail_hex, 16)
    codepoint = 0x10000 + (lead - 0xD800) * 0x400 + (trail - 0xDC00)

    codepoint not in 0x10400..0x104AF and codepoint not in 0x1D400..0x1D7FF
  end

  defp regexp_group_name_start?(ch) when ch in ["_", "$", "\\"], do: true

  defp regexp_group_name_start?(ch) do
    String.match?(ch, ~r/^\p{L}$/u) or regexp_group_name_math_alphanumeric?(ch)
  end

  defp regexp_group_name_part?(ch) when ch in ["{", "}"], do: true

  defp regexp_group_name_part?(ch) do
    regexp_group_name_start?(ch) or String.match?(ch, ~r/^\p{N}$/u)
  end

  defp regexp_group_name_math_alphanumeric?(ch) do
    case String.to_charlist(ch) do
      [codepoint] -> codepoint in 0x1D400..0x1D7FF
      _other -> false
    end
  end

  defp regexp_backreference_error(pattern, offset, _names) when offset >= byte_size(pattern),
    do: nil

  defp regexp_backreference_error(pattern, offset, names) do
    case :binary.match(pattern, "\\k", scope: {offset, byte_size(pattern) - offset}) do
      :nomatch ->
        nil

      {index, 2} ->
        if index + 2 >= byte_size(pattern) or :binary.at(pattern, index + 2) != ?< do
          "expecting group name"
        else
          case read_regexp_group_name(pattern, index + 3) do
            {:ok, name, next_offset} ->
              if MapSet.member?(names, name),
                do: regexp_backreference_error(pattern, next_offset, names),
                else: "group name not defined"

            :error ->
              "expecting group name"
          end
        end
    end
  end

  defp binary_part?(binary, part), do: :binary.match(binary, part) != :nomatch
end
