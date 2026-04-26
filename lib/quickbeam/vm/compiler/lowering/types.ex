defmodule QuickBEAM.VM.Compiler.Lowering.Types do
  @moduledoc "Small type and purity predicates used while lowering compiler IR."

  @doc "Infers a coarse VM type for an Erlang abstract expression."
  def infer_expr_type({:integer, _, _}), do: :integer
  def infer_expr_type({:float, _, _}), do: :number
  def infer_expr_type({:char, _, _}), do: :integer
  def infer_expr_type({:string, _, _}), do: :string
  def infer_expr_type({:bin, _, _}), do: :string
  def infer_expr_type({:atom, _, true}), do: :boolean
  def infer_expr_type({:atom, _, false}), do: :boolean
  def infer_expr_type({:atom, _, :undefined}), do: :undefined
  def infer_expr_type({:atom, _, nil}), do: :null
  def infer_expr_type(_), do: :unknown

  @doc "Returns whether a slot is definitely initialized."
  def definitely_initialized?(:unknown), do: false
  def definitely_initialized?(_), do: true

  @doc "Returns whether an expression can be duplicated without side effects."
  def pure_expr?({:integer, _, _}), do: true
  def pure_expr?({:float, _, _}), do: true
  def pure_expr?({:char, _, _}), do: true
  def pure_expr?({:string, _, _}), do: true
  def pure_expr?({:atom, _, _}), do: true
  def pure_expr?({nil, _}), do: true
  def pure_expr?({:var, _, _}), do: true
  def pure_expr?({:tuple, _, values}), do: Enum.all?(values, &pure_expr?/1)
  def pure_expr?({:cons, _, head, tail}), do: pure_expr?(head) and pure_expr?(tail)
  def pure_expr?({:map, _, fields}), do: Enum.all?(fields, &pure_map_field?/1)
  def pure_expr?(_), do: false

  defp pure_map_field?({:map_field_assoc, _, key, value}),
    do: pure_expr?(key) and pure_expr?(value)

  defp pure_map_field?(_), do: false
end
