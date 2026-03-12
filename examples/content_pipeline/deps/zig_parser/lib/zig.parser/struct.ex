defmodule Zig.Parser.Struct do
  defstruct [:location, :backed, packed: false, extern: false, decls: [], fields: []]

  defmodule Field do
    defstruct [:name, :doc_comment, :type, :value]

    def parse(name, type, [:=, value | rest]) do
      {%__MODULE__{name: name, type: type, value: value}, strip_comma(rest)}
    end

    def parse(name, type, rest) do
      {%__MODULE__{name: name, type: type}, strip_comma(rest)}
    end

    defp strip_comma([:COMMA | rest]), do: rest
    defp strip_comma(rest), do: rest
  end

  def parse([:LPAREN, backing, :RPAREN | rest]), do: %{parse(rest) | backed: backing}

  def parse([:LBRACE | rest]), do: do_parse(%__MODULE__{}, rest)

  defp do_parse(struct, [{:doc_comment, doc_comment}, name, :COLON, type | rest]) do
    {field, rest} = Field.parse(name, type, rest)

    struct
    |> Map.update!(:fields, &[%{field | doc_comment: doc_comment} | &1])
    |> do_parse(rest)
  end

  defp do_parse(struct, [name, :COLON, type | rest]) do
    {field, rest} = Field.parse(name, type, rest)

    struct
    |> Map.update!(:fields, &[field | &1])
    |> do_parse(rest)
  end

  defp do_parse(struct, [:RBRACE]) do
    Map.update!(struct, :decls, &Enum.reverse/1)
  end

  defp do_parse(struct, [decl | rest]) do
    struct
    |> Map.update!(:decls, &[decl | &1])
    |> do_parse(rest)
  end
end
