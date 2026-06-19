defmodule QuickBEAM.JS.Compiler.Operators do
  @moduledoc false

  def binary("+"), do: {:ok, :add}
  def binary("-"), do: {:ok, :sub}
  def binary("*"), do: {:ok, :mul}
  def binary("**"), do: {:ok, :pow}
  def binary("/"), do: {:ok, :div}
  def binary("%"), do: {:ok, :mod}
  def binary("<<"), do: {:ok, :shl}
  def binary(">>"), do: {:ok, :sar}
  def binary(">>>"), do: {:ok, :shr}
  def binary("&"), do: {:ok, :band}
  def binary("^"), do: {:ok, :bxor}
  def binary("|"), do: {:ok, :bor}
  def binary("in"), do: {:ok, :in}
  def binary("instanceof"), do: {:ok, :instanceof}
  def binary("<"), do: {:ok, :lt}
  def binary("<="), do: {:ok, :lte}
  def binary(">"), do: {:ok, :gt}
  def binary(">="), do: {:ok, :gte}
  def binary("=="), do: {:ok, :eq}
  def binary("!="), do: {:ok, :neq}
  def binary("==="), do: {:ok, :strict_eq}
  def binary("!=="), do: {:ok, :strict_neq}
  def binary(operator), do: {:error, {:unsupported, {:binary_operator, operator}}}

  def compound("+="), do: {:ok, :add}
  def compound("-="), do: {:ok, :sub}
  def compound("*="), do: {:ok, :mul}
  def compound("**="), do: {:ok, :pow}
  def compound("/="), do: {:ok, :div}
  def compound("%="), do: {:ok, :mod}
  def compound("<<="), do: {:ok, :shl}
  def compound(">>="), do: {:ok, :sar}
  def compound(">>>="), do: {:ok, :shr}
  def compound("&="), do: {:ok, :band}
  def compound("^="), do: {:ok, :bxor}
  def compound("|="), do: {:ok, :bor}
  def compound(operator), do: {:error, {:unsupported, {:assignment_operator, operator}}}

  def update("++", true), do: {:ok, :inc}
  def update("--", true), do: {:ok, :dec}
  def update("++", false), do: {:ok, :post_inc}
  def update("--", false), do: {:ok, :post_dec}
  def update(operator, _prefix), do: {:error, {:unsupported, {:update_operator, operator}}}

  def unary("-"), do: {:ok, :neg}
  def unary("+"), do: {:ok, :plus}
  def unary("!"), do: {:ok, :lnot}
  def unary("~"), do: {:ok, :not}
  def unary("typeof"), do: {:ok, :typeof}
  def unary(operator), do: {:error, {:unsupported, {:unary_operator, operator}}}
end
