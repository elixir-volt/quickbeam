defmodule Zig.Parser.Enum do
  defstruct [:location, :backed, packed: false, extern: false, decls: [], fields: []]

  def parse([:LPAREN, backing, :RPAREN | rest]), do: %{parse(rest) | backed: backing}

  def parse([:LBRACE | rest]), do: do_parse(%__MODULE__{}, rest)

  defp do_parse(struct, [name, :=, value | rest]) do
    struct
    |> Map.update!(:fields, &[{name, value} | &1])
    |> do_parse(rest)
  end

  defp do_parse(struct, [:RBRACE]) do
    struct
    |> Map.update!(:decls, &Enum.reverse/1)
    |> Map.update!(:fields, &Enum.reverse/1)
  end

  defp do_parse(struct, [name, :COMMA | rest]) when is_atom(name) do
    struct
    |> Map.update!(:fields, &[name | &1])
    |> do_parse(rest)
  end

  defp do_parse(struct, [name, :RBRACE]) when is_atom(name) do
    struct
    |> Map.update!(:decls, &Enum.reverse/1)
    |> Map.update!(:fields, &Enum.reverse([name | &1]))
  end

  defp do_parse(struct, [decl | rest]) do
    struct
    |> Map.update!(:decls, &[decl | &1])
    |> do_parse(rest)
  end
end
