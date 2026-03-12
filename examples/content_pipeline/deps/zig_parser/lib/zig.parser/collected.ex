defmodule Zig.Parser.Collected do
  @literals ~w[integer char float string]a

  def literals, do: @literals

  def post_traverse(rest, [string | args_rest], context, _, _, :line_string) do
    {rest, [string | args_rest], context}
  end

  def post_traverse(rest, ["0x" <> hex | args_rest], context, _, _, :INTEGER) do
    {rest, [{:integer, String.to_integer(remove_underscore(hex), 16)} | args_rest], context}
  end

  def post_traverse(rest, ["0o" <> oct | args_rest], context, _, _, :INTEGER) do
    {rest, [{:integer, String.to_integer(remove_underscore(oct), 8)} | args_rest], context}
  end

  def post_traverse(rest, ["0b" <> bin | args_rest], context, _, _, :INTEGER) do
    {rest, [{:integer, String.to_integer(remove_underscore(bin), 16)} | args_rest], context}
  end

  def post_traverse(rest, [integer | args_rest], context, _, _, :INTEGER) do
    {rest, [{:integer, String.to_integer(remove_underscore(integer))} | args_rest], context}
  end

  def post_traverse(rest, [float_str | args_rest], context, _, _, :FLOAT) do
    # the zig parser itself should know that this is inherently a float.
    token =
      float_str
      |> remove_underscore()
      |> Float.parse()
      |> case do
        {float, ""} -> {:float, float}
        _ -> {:extended_float, float_str}
      end

    {rest, [token | args_rest], context}
  rescue
    ArgumentError ->
      {rest, [{:extended_float, float_str} | args_rest], context}
  end

  def post_traverse(rest, [string | args_rest], context, _, _, :STRINGLITERAL) do
    {rest, [{:string, String.trim(string, ~S("))} | args_rest], context}
  end

  def post_traverse(rest, [string | args_rest], context, _, _, :BUILTINIDENTIFIER) do
    builtin =
      string
      |> String.trim_leading("@")
      |> String.to_atom()

    {rest, [{:builtin, builtin} | args_rest], context}
  end

  defp remove_underscore(string), do: String.replace(string, "_", "")
end
