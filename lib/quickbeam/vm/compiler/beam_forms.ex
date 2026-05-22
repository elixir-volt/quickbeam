defmodule QuickBEAM.VM.Compiler.BeamForms do
  @moduledoc "Shared Erlang abstract-format form builders used by compiler assembly and lowering."

  @line 1

  def line, do: @line

  def block_name(idx), do: String.to_atom("block_#{idx}")

  def var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  def var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  def var(name) when is_atom(name), do: {:var, @line, name}

  def integer(value), do: {:integer, @line, value}
  def atom(value), do: {:atom, @line, value}
  def literal(value), do: :erl_parse.abstract(value)
  def match(left, right), do: {:match, @line, left, right}
  def tuple(values), do: {:tuple, @line, values}
  def op(operator, operand), do: {:op, @line, operator, operand}
  def op(operator, left, right), do: {:op, @line, operator, left, right}

  def nil_expr, do: {nil, @line}
  def cons(head, tail), do: {:cons, @line, head, tail}
  def list([]), do: nil_expr()
  def list([head | tail]), do: cons(head, list(tail))

  def map(entries) do
    {:map, @line, Enum.map(entries, fn {key, value} -> {:map_field_assoc, @line, key, value} end)}
  end

  def remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, literal(mod), atom(fun)}, args}
  end

  def local_call(fun, args), do: {:call, @line, atom(fun), args}

  def tuple_element(tuple, index), do: remote_call(:erlang, :element, [integer(index), tuple])

  def case_(expr, clauses), do: {:case, @line, expr, clauses}

  def clause(patterns, guards \\ [], body), do: {:clause, @line, patterns, guards, body}

  def function(name, arity, clauses), do: {:function, @line, name, arity, clauses}

  def guard_call(fun, args), do: {:call, @line, atom(fun), args}

  def binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end
end
