defmodule QuickBEAM.VM.ABI.Source do
  @moduledoc """
  Parses the small, fixed C declaration forms used by the vendored QuickJS ABI.

  This is deliberately not a general C parser. Unsupported declarations fail
  explicitly instead of being accepted through permissive text matching.
  """

  @doc "Returns the value of an exact preprocessor definition."
  @spec define!(String.t(), String.t()) :: String.t()
  def define!(source, name) when is_binary(source) and is_binary(name) do
    source
    |> lines()
    |> Enum.find_value(fn line -> definition_value(line, name) end)
    |> case do
      nil -> raise ArgumentError, "#{name} not found in vendored source"
      value -> value
    end
  end

  @doc "Returns comma-separated entries from one exact typedef enum declaration."
  @spec enum_entries!(String.t(), String.t()) :: [String.t()]
  def enum_entries!(source, name) when is_binary(source) and is_binary(name) do
    opening = "typedef enum #{name} {"
    closing = "} #{name};"

    case Enum.split_while(lines(source), &(String.trim(&1) != opening)) do
      {_before, []} ->
        raise ArgumentError, "#{name} not found in vendored source"

      {_before, [_opening | body]} ->
        {entries, remainder} = Enum.split_while(body, &(String.trim(&1) != closing))

        if remainder == [] do
          raise ArgumentError, "unterminated #{name} in vendored source"
        end

        entries
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc "Returns argument lists from exact invocations of a C-style macro."
  @spec macro_arguments(String.t(), String.t()) :: [[String.t()]]
  def macro_arguments(source, name) when is_binary(source) and is_binary(name) do
    prefix = name <> "("

    source
    |> lines()
    |> Enum.flat_map(fn line ->
      case String.trim_leading(line) do
        ^prefix <> rest -> [parse_macro_arguments!(rest, name)]
        _other -> []
      end
    end)
  end

  defp lines(source), do: String.split(source, ["\r\n", "\n"])

  defp definition_value(line, name) do
    case String.split(String.trim(line), [" ", "\t"], trim: true) do
      ["#define", ^name, value] -> value
      _other -> nil
    end
  end

  defp parse_macro_arguments!(rest, name) do
    rest
    |> String.to_charlist()
    |> take_macro_body([], false, false, name)
    |> split_arguments([], [], false, false)
    |> Enum.map(&(&1 |> Enum.reverse() |> to_string() |> String.trim()))
  end

  defp take_macro_body([], _body, _quoted?, _escaped?, name),
    do: raise(ArgumentError, "unterminated #{name} invocation in vendored source")

  defp take_macro_body([?) | _rest], body, false, false, _name), do: Enum.reverse(body)

  defp take_macro_body([?\\ = char | rest], body, true, false, name),
    do: take_macro_body(rest, [char | body], true, true, name)

  defp take_macro_body([char | rest], body, quoted?, true, name),
    do: take_macro_body(rest, [char | body], quoted?, false, name)

  defp take_macro_body([?" = char | rest], body, quoted?, false, name),
    do: take_macro_body(rest, [char | body], not quoted?, false, name)

  defp take_macro_body([char | rest], body, quoted?, false, name),
    do: take_macro_body(rest, [char | body], quoted?, false, name)

  defp split_arguments([], argument, arguments, false, false),
    do: Enum.reverse([argument | arguments])

  defp split_arguments([], _argument, _arguments, true, _escaped?),
    do: raise(ArgumentError, "unterminated string in vendored macro invocation")

  defp split_arguments([?, | rest], argument, arguments, false, false),
    do: split_arguments(rest, [], [argument | arguments], false, false)

  defp split_arguments([?\\ = char | rest], argument, arguments, true, false),
    do: split_arguments(rest, [char | argument], arguments, true, true)

  defp split_arguments([char | rest], argument, arguments, quoted?, true),
    do: split_arguments(rest, [char | argument], arguments, quoted?, false)

  defp split_arguments([?" = char | rest], argument, arguments, quoted?, false),
    do: split_arguments(rest, [char | argument], arguments, not quoted?, false)

  defp split_arguments([char | rest], argument, arguments, quoted?, false),
    do: split_arguments(rest, [char | argument], arguments, quoted?, false)
end
