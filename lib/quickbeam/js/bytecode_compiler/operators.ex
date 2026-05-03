defmodule QuickBEAM.JS.BytecodeCompiler.Operators do
  @moduledoc false

  def binary("+"), do: {:ok, :add}
  def binary("-"), do: {:ok, :sub}
  def binary("*"), do: {:ok, :mul}
  def binary("/"), do: {:ok, :div}
  def binary("%"), do: {:ok, :mod}
  def binary("<"), do: {:ok, :lt}
  def binary("<="), do: {:ok, :lte}
  def binary(">"), do: {:ok, :gt}
  def binary(">="), do: {:ok, :gte}
  def binary("=="), do: {:ok, :eq}
  def binary("!="), do: {:ok, :neq}
  def binary("==="), do: {:ok, :strict_eq}
  def binary("!=="), do: {:ok, :strict_neq}
  def binary(operator), do: {:error, {:unsupported, {:binary_operator, operator}}}

  def unary("-"), do: {:ok, :neg}
  def unary("+"), do: {:ok, :plus}
  def unary("!"), do: {:ok, :lnot}
  def unary("typeof"), do: {:ok, :typeof}
  def unary(operator), do: {:error, {:unsupported, {:unary_operator, operator}}}
end
