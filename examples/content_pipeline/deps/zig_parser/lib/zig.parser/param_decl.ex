defmodule Zig.Parser.ParamDecl do
  defstruct [
    :name,
    :doc_comment,
    :type,
    comptime: false,
    noalias: false
  ]

  def post_traverse(rest, [{:ParamDecl, args}], context, _, _) do
    {rest, [parse(args)], context}
  end

  defp parse([{:doc_comment, comment} | rest]) do
    %{parse(rest) | doc_comment: comment}
  end

  defp parse([:comptime | rest]), do: %{parse(rest) | comptime: true}

  defp parse([:noalias | rest]), do: %{parse(rest) | noalias: true}

  defp parse([identifier, :COLON | rest]), do: %{parse_type(rest) | name: identifier}

  defp parse([type]), do: parse_type([type])

  defp parse_type([:...]), do: %__MODULE__{type: :...}

  defp parse_type([type]), do: %__MODULE__{type: type}
end
