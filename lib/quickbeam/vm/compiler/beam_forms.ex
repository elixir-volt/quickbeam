defmodule QuickBEAM.VM.Compiler.BEAMForms do
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
  def try_catch(try_body, catch_clauses), do: {:try, @line, try_body, [], catch_clauses, []}
  def op(operator, operand), do: {:op, @line, operator, operand}
  def op(operator, left, right), do: {:op, @line, operator, left, right}
  def equal(left, right), do: op(:==, left, right)
  def not_equal(left, right), do: op(:"=/=", left, right)
  def or_else(left, right), do: op(:orelse, left, right)
  def and_also(left, right), do: op(:andalso, left, right)

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
  def false_clause(body), do: clause([atom(false)], [], body)
  def true_clause(body), do: clause([atom(true)], [], body)

  def function(name, arity, clauses), do: {:function, @line, name, arity, clauses}

  def function(name, args, guards, body),
    do: function(name, length(args), [clause(args, guards, body)])

  def guard_call(fun, args), do: {:call, @line, atom(fun), args}
  def is_number_guard(expr), do: guard_call(:is_number, [expr])
  def is_integer_guard(expr), do: guard_call(:is_integer, [expr])
  def is_float_guard(expr), do: guard_call(:is_float, [expr])
  def is_binary_guard(expr), do: guard_call(:is_binary, [expr])

  def binary(elements), do: {:bin, @line, elements}

  def binary_element(expr, spec \\ :default, flags \\ [:binary]),
    do: {:bin_element, @line, expr, spec, flags}

  def binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end
end
