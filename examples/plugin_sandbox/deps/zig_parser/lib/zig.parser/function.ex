defmodule Zig.Parser.Function do
  alias Zig.Parser

  defstruct [
    :location,
    :doc_comment,
    :block,
    :name,
    :params,
    :type,
    :alignment,
    :linksection,
    :callconv,
    :addrspace,
    impliciterror: false,
    builtin: false,
    extern: false,
    export: false,
    pub: false,
    inline: :maybe
  ]

  def post_traverse(rest, [{:FnProto, [start, :fn | args]} | rest_args], context, _, _) do
    fun_struct =
      args
      |> parse
      |> Parser.put_location(start)

    {rest, [fun_struct | rest_args], context}
  end

  # type declaration
  def parse([:LPAREN, {:ParamDeclList, params}, :RPAREN | rest]) do
    parse_decl(rest, %__MODULE__{params: parse_params(params, [])})
  end

  def parse([name, :LPAREN, {:ParamDeclList, params}, :RPAREN | rest]) do
    parse_decl(rest, %__MODULE__{name: name, params: parse_params(params, [])})
  end

  def parse([name, :LPAREN, {:ExprList, params}, :RPAREN]) do
    %__MODULE__{name: name, params: params}
  end

  defp parse_decl([{:addrspace, addrspace} | rest], fun_struct) do
    parse_decl(rest, %{fun_struct | addrspace: addrspace})
  end

  defp parse_decl([{:align, align} | rest], fun_struct) do
    parse_decl(rest, %{fun_struct | alignment: align})
  end

  defp parse_decl([{:callconv, callconv} | rest], fun_struct) do
    parse_decl(rest, %{fun_struct | callconv: callconv})
  end

  defp parse_decl([{:linksection, linksection} | rest], fun_struct) do
    parse_decl(rest, %{fun_struct | linksection: linksection})
  end

  defp parse_decl([:! | rest], fun_struct) do
    parse_decl(rest, %{fun_struct | impliciterror: true})
  end

  defp parse_decl([type], fun_struct), do: %{fun_struct | type: type}

  defp parse_params([identifier, :COMMA], so_far), do: Enum.reverse(so_far, [identifier])

  defp parse_params([identifier], so_far), do: Enum.reverse(so_far, [identifier])

  defp parse_params([identifier, :COMMA | rest], so_far),
    do: parse_params(rest, [identifier | so_far])

  defp parse_params([], []), do: []
end
