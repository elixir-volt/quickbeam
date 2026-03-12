defmodule Zig.Parser.ComptimeDecl do
  def post_traverse(rest, [{:ComptimeDecl, [:comptime, content]} | rest_args], context, _, _) do
    case content do
      %{comptime: _} ->
        {rest, [%{content | comptime: true} | rest_args], context}

      _ ->
        {:comptime, content}
    end
  end
end
