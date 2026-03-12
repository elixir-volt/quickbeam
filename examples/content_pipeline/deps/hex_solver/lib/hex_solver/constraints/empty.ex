defmodule HexSolver.Constraints.Empty do
  @moduledoc false

  use HexSolver.Constraints.Impl

  alias HexSolver.Constraint
  alias HexSolver.Constraints.Empty

  defstruct []

  def any?(%Empty{}), do: false

  def empty?(%Empty{}), do: true

  def allows?(%Empty{}, %Version{}), do: false

  def allows_any?(%Empty{}, constraint), do: Constraint.empty?(constraint)

  def allows_all?(%Empty{}, constraint), do: Constraint.empty?(constraint)

  def difference(%Empty{}, _constraint), do: %Empty{}

  def intersect(%Empty{}, _constraint), do: %Empty{}

  def union(%Empty{}, constraint), do: constraint

  def compare(left, right) do
    raise FunctionClauseError,
      module: __MODULE__,
      function: :compare,
      arity: 2,
      kind: :def,
      args: [left, right],
      clauses: []
  end

  def to_string(%Empty{}) do
    "empty"
  end

  defimpl String.Chars do
    defdelegate to_string(empty), to: HexSolver.Constraints.Empty
  end

  defimpl Inspect do
    def inspect(_, _opts) do
      "#Empty<>"
    end
  end
end
