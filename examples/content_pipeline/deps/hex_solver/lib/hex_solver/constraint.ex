defprotocol HexSolver.Constraint do
  @moduledoc false

  def any?(constraint)
  def empty?(constraint)
  def allows?(constraint, version)
  def allows_any?(left, right)
  def allows_all?(left, right)
  def difference(left, right)
  def intersect(left, right)
  def union(left, right)
  def compare(left, right)
end
