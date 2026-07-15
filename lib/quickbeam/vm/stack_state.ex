defmodule QuickBEAM.VM.StackState do
  @moduledoc """
  Applies verified literal and operand-stack transformations to compact stack state.

  The interpreter and generated compiler blocks share this module so stack
  permutation semantics have one implementation.
  """

  @type result :: {:ok, [term()]} | {:error, term()}

  @doc "Transforms a verified operand stack for one stack-family instruction."
  @spec execute(atom(), [term()], [term()], term(), [term()]) :: result()
  def execute(name, [value], stack, _this, _constants)
      when name in [:push_i32, :push_i8, :push_i16],
      do: {:ok, [value | stack]}

  def execute(:push_bigint_i32, [value], stack, _this, _constants),
    do: {:ok, [{:bigint, value} | stack]}

  def execute(:undefined, [], stack, _this, _constants), do: {:ok, [:undefined | stack]}
  def execute(:null, [], stack, _this, _constants), do: {:ok, [nil | stack]}
  def execute(:push_false, [], stack, _this, _constants), do: {:ok, [false | stack]}
  def execute(:push_true, [], stack, _this, _constants), do: {:ok, [true | stack]}
  def execute(:push_this, [], stack, this, _constants), do: {:ok, [this | stack]}

  def execute(name, [index], stack, _this, constants) when name in [:push_const, :push_const8],
    do: {:ok, [Enum.at(constants, index) | stack]}

  def execute(:drop, [], [_value | stack], _this, _constants), do: {:ok, stack}
  def execute(:dup, [], [value | _] = stack, _this, _constants), do: {:ok, [value | stack]}

  def execute(:dup1, [], [a, b | stack], _this, _constants),
    do: {:ok, [a, b, b | stack]}

  def execute(:dup2, [], [a, b | stack], _this, _constants),
    do: {:ok, [a, b, a, b | stack]}

  def execute(:dup3, [], [a, b, c | stack], _this, _constants),
    do: {:ok, [a, b, c, a, b, c | stack]}

  def execute(name, [], [a, _b | stack], _this, _constants) when name in [:nip, :nip_catch],
    do: {:ok, [a | stack]}

  def execute(:nip1, [], [a, b, _c | stack], _this, _constants), do: {:ok, [a, b | stack]}
  def execute(:swap, [], [a, b | stack], _this, _constants), do: {:ok, [b, a | stack]}

  def execute(:swap2, [], [a, b, c, d | stack], _this, _constants),
    do: {:ok, [c, d, a, b | stack]}

  def execute(:perm3, [], [a, b, c | stack], _this, _constants),
    do: {:ok, [a, c, b | stack]}

  def execute(:perm4, [], [a, b, c, d | stack], _this, _constants),
    do: {:ok, [a, c, d, b | stack]}

  def execute(:perm5, [], [a, b, c, d, e | stack], _this, _constants),
    do: {:ok, [a, c, d, e, b | stack]}

  def execute(:rot3l, [], [a, b, c | stack], _this, _constants),
    do: {:ok, [c, a, b | stack]}

  def execute(:rot3r, [], [a, b, c | stack], _this, _constants),
    do: {:ok, [b, c, a | stack]}

  def execute(:rot4l, [], [a, b, c, d | stack], _this, _constants),
    do: {:ok, [d, a, b, c | stack]}

  def execute(:rot5l, [], [a, b, c, d, e | stack], _this, _constants),
    do: {:ok, [e, a, b, c, d | stack]}

  def execute(:insert2, [], [a, b | stack], _this, _constants),
    do: {:ok, [a, b, a | stack]}

  def execute(:insert3, [], [a, b, c | stack], _this, _constants),
    do: {:ok, [a, b, c, a | stack]}

  def execute(name, operands, stack, _this, _constants),
    do: {:error, {:invalid_stack_operation, name, operands, stack}}
end
