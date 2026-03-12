defmodule Zig.Parser.GlobalVarDecl do
  alias Zig.Parser.Const
  alias Zig.Parser.Var

  def post_traverse(rest, args, context, _loc, _row) do
    {decl, rest_args} =
      case Enum.reverse(args) do
        [%Const{} = const | exts] -> Const.extend(const, exts)
        [%Var{} = var | exts] -> Var.extend(var, exts)
      end

    {rest, [decl | rest_args], context}
  end
end
