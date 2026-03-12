defmodule Zig.Parser.Union do
  defstruct [:location, :tag, packed: false, extern: false, decls: [], fields: %{}]

  def parse([:LPAREN, tagtype, :RPAREN | rest]), do: %{parse(rest) | tag: tagtype}

  def parse([:LPAREN, :enum | rest]) do
    {type, rest} = parse_enum_type(rest)
    %{parse(rest) | tag: type}
  end

  def parse([:LBRACE | rest]), do: parse(%__MODULE__{}, rest)

  defp parse(struct, [name, :COLON, type | rest]) do
    struct
    |> Map.update!(:fields, &Map.put(&1, name, type))
    |> parse(rest)
  end

  defp parse(struct, [:RBRACE]) do
    Map.update!(struct, :decls, &Enum.reverse/1)
  end

  defp parse(struct, [decl | rest]) do
    struct
    |> Map.update!(:decls, &[decl | &1])
    |> parse(rest)
  end

  defp parse_enum_type([:LPAREN, type, :RPAREN, :RPAREN | rest]) do
    {type, rest}
  end

  defp parse_enum_type([:RPAREN | rest]) do
    {:_, rest}
  end
end
