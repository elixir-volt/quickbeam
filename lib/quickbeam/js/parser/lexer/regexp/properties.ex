defmodule QuickBEAM.JS.Parser.Lexer.Regexp.Properties do
  @moduledoc "Unicode property escape and class range validation."

  @unicode_aliases_by_table (fn ->
                               table =
                                 Application.app_dir(
                                   :quickbeam,
                                   "priv/c_src/libunicode-table.h"
                                 )
                                 |> File.read!()

                               parse_aliases = fn name ->
                                 pattern =
                                   ~r/static const char #{name}\[\] =\n(.*?);/s

                                 [body] = Regex.run(pattern, table, capture: :all_but_first)

                                 ~r/"([^"]*)"\s*"\\0"/
                                 |> Regex.scan(body, capture: :all_but_first)
                                 |> List.flatten()
                                 |> Enum.flat_map(&String.split(&1, ","))
                                 |> MapSet.new()
                               end

                               %{
                                 binary_properties: parse_aliases.("unicode_prop_name_table"),
                                 general_categories: parse_aliases.("unicode_gc_name_table"),
                                 scripts: parse_aliases.("unicode_script_name_table")
                               }
                             end).()

  @unicode_binary_properties Map.fetch!(@unicode_aliases_by_table, :binary_properties)
  @unicode_general_categories Map.fetch!(@unicode_aliases_by_table, :general_categories)
  @unicode_scripts @unicode_aliases_by_table
                   |> Map.fetch!(:scripts)
                   |> MapSet.union(MapSet.new(~w[Unknown Zzzz]))
  @unicode_string_properties MapSet.new(~w[
    Basic_Emoji Emoji_Keycap_Sequence RGI_Emoji RGI_Emoji_Flag_Sequence
    RGI_Emoji_Modifier_Sequence RGI_Emoji_Tag_Sequence RGI_Emoji_ZWJ_Sequence
  ])

  def regexp_class_range_error(pattern, flags) do
    if is_binary(flags) and (binary_part?(flags, "u") or binary_part?(flags, "v")) and
         (String.match?(pattern, ~r/\[[^\]]*\\[dDsSwWpP](?:\{[^\]]*\})?-/) or
            String.match?(pattern, ~r/\[[^\]]*-\\[dDsSwWpP](?:\{[^\]]*\})?/)) do
      "invalid class range"
    end
  end

  def regexp_property_escape_error(pattern, flags) do
    if is_binary(flags) and (binary_part?(flags, "u") or binary_part?(flags, "v")) do
      regexp_property_escape_error_in_pattern(pattern, false, binary_part?(flags, "v"))
    end
  end

  defp regexp_property_escape_error_in_pattern(<<>>, _in_class?, _allow_string_properties?),
    do: nil

  defp regexp_property_escape_error_in_pattern(
         <<?\\, ?\\, marker, ?{, _rest::binary>>,
         _in_class?,
         _allow_string_properties?
       )
       when marker in [?p, ?P],
       do: "invalid repetition count"

  defp regexp_property_escape_error_in_pattern(
         <<?\\, marker, rest::binary>>,
         in_class?,
         allow_string_properties?
       )
       when marker in [?p, ?P] do
    case rest do
      <<?{, property_rest::binary>> ->
        validate_regexp_property_escape(property_rest, in_class?, allow_string_properties?)

      _ ->
        "expecting '{' after \\p"
    end
  end

  defp regexp_property_escape_error_in_pattern(
         <<?\\, _escaped, rest::binary>>,
         in_class?,
         allow_string_properties?
       ),
       do: regexp_property_escape_error_in_pattern(rest, in_class?, allow_string_properties?)

  defp regexp_property_escape_error_in_pattern(
         <<?[, rest::binary>>,
         false,
         allow_string_properties?
       ),
       do: regexp_property_escape_error_in_pattern(rest, true, allow_string_properties?)

  defp regexp_property_escape_error_in_pattern(
         <<?], rest::binary>>,
         true,
         allow_string_properties?
       ),
       do: regexp_property_escape_error_in_pattern(rest, false, allow_string_properties?)

  defp regexp_property_escape_error_in_pattern(
         <<_byte, rest::binary>>,
         in_class?,
         allow_string_properties?
       ),
       do: regexp_property_escape_error_in_pattern(rest, in_class?, allow_string_properties?)

  defp validate_regexp_property_escape(rest, in_class?, allow_string_properties?) do
    case take_regexp_property_escape(rest, []) do
      {:ok, property, rest} ->
        case regexp_property_error(property, allow_string_properties?) do
          nil ->
            regexp_property_escape_error_in_pattern(rest, in_class?, allow_string_properties?)

          error ->
            error
        end

      :error ->
        "expecting '}'"
    end
  end

  defp take_regexp_property_escape(<<>>, _acc), do: :error

  defp take_regexp_property_escape(<<?}, rest::binary>>, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp take_regexp_property_escape(<<byte, rest::binary>>, acc),
    do: take_regexp_property_escape(rest, [byte | acc])

  defp regexp_property_error("", _allow_string_properties?), do: "unknown unicode property name"

  defp regexp_property_error(property, allow_string_properties?) do
    if allow_string_properties? and MapSet.member?(@unicode_string_properties, property) do
      nil
    else
      regexp_codepoint_property_error(property)
    end
  end

  defp regexp_codepoint_property_error(property) do
    case String.split(property, "=", parts: 2) do
      [name] -> regexp_lone_property_error(name)
      [name, value] -> regexp_named_property_error(name, value)
    end
  end

  defp regexp_lone_property_error(name) do
    cond do
      MapSet.member?(@unicode_general_categories, name) -> nil
      MapSet.member?(@unicode_binary_properties, name) -> nil
      true -> "unknown unicode property name"
    end
  end

  defp regexp_named_property_error(_name, ""), do: "unknown unicode property name"

  defp regexp_named_property_error(name, value) when name in ["Script", "sc"] do
    if MapSet.member?(@unicode_scripts, value), do: nil, else: "unknown unicode script"
  end

  defp regexp_named_property_error(name, value) when name in ["Script_Extensions", "scx"] do
    if MapSet.member?(@unicode_scripts, value), do: nil, else: "unknown unicode script"
  end

  defp regexp_named_property_error(name, value) when name in ["General_Category", "gc"] do
    if MapSet.member?(@unicode_general_categories, value),
      do: nil,
      else: "unknown unicode general category"
  end

  defp regexp_named_property_error(_name, _value), do: "unknown unicode property name"

  defp binary_part?(binary, part), do: :binary.match(binary, part) != :nomatch
end
