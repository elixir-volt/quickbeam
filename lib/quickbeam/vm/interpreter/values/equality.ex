defmodule QuickBEAM.VM.Interpreter.Values.Equality do
  @moduledoc "JS equality operations: eq, neq, strict_eq, abstract_eq."

  alias QuickBEAM.VM.Interpreter.Values.Coercion

  @doc "Applies JavaScript strict equality semantics."
  def strict_eq(:nan, :nan), do: false
  def strict_eq(:infinity, :infinity), do: true
  def strict_eq(:neg_infinity, :neg_infinity), do: true
  def strict_eq({:bigint, a}, {:bigint, b}), do: a == b
  def strict_eq({:symbol, _, ref1}, {:symbol, _, ref2}), do: ref1 === ref2
  def strict_eq(a, b) when is_number(a) and is_number(b), do: a == b
  def strict_eq(a, b), do: a === b

  @doc "Applies JavaScript abstract equality semantics."
  def eq({:bigint, a}, {:bigint, b}), do: a == b
  def eq(a, b), do: abstract_eq(a, b)

  @doc "Applies JavaScript abstract inequality semantics."
  def neq(a, b), do: not eq(a, b)

  @doc "Applies the core JavaScript abstract equality algorithm."
  def abstract_eq(nil, nil), do: true
  def abstract_eq(nil, :undefined), do: true
  def abstract_eq(:undefined, nil), do: true
  def abstract_eq(:undefined, :undefined), do: true
  def abstract_eq(:nan, _), do: false
  def abstract_eq(_, :nan), do: false
  def abstract_eq(:infinity, :infinity), do: true
  def abstract_eq(:neg_infinity, :neg_infinity), do: true
  def abstract_eq(:infinity, b) when is_number(b), do: false
  def abstract_eq(:neg_infinity, b) when is_number(b), do: false
  def abstract_eq(a, :infinity) when is_number(a), do: false
  def abstract_eq(a, :neg_infinity) when is_number(a), do: false
  def abstract_eq({:bigint, a}, {:bigint, b}), do: a == b
  def abstract_eq(a, b) when is_number(a) and is_number(b), do: a == b
  def abstract_eq(a, b) when is_binary(a) and is_binary(b), do: a == b
  def abstract_eq(a, b) when is_boolean(a) and is_boolean(b), do: a == b
  def abstract_eq(true, b), do: abstract_eq(1, b)
  def abstract_eq(a, true), do: abstract_eq(a, 1)
  def abstract_eq(false, b), do: abstract_eq(0, b)
  def abstract_eq(a, false), do: abstract_eq(a, 0)
  def abstract_eq(a, b) when is_number(a) and is_binary(b), do: a == Coercion.to_number(b)
  def abstract_eq(a, b) when is_binary(a) and is_number(b), do: Coercion.to_number(a) == b
  def abstract_eq({:bigint, a}, b) when is_integer(b), do: a == b
  def abstract_eq({:bigint, a}, b) when is_float(b), do: a == b

  def abstract_eq({:bigint, a}, b) when is_binary(b) do
    case String.trim(b) do
      "" ->
        a == 0

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} -> a == n
          _ -> false
        end
    end
  end

  def abstract_eq(a, {:bigint, b}) when is_binary(a) do
    case String.trim(a) do
      "" ->
        0 == b

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} -> n == b
          _ -> false
        end
    end
  end

  def abstract_eq(a, {:bigint, b}) when is_integer(a), do: a == b
  def abstract_eq(a, {:bigint, b}) when is_float(a), do: a == b

  def abstract_eq({:bigint, _} = a, b) when is_boolean(b),
    do: abstract_eq(a, Coercion.to_number(b))

  def abstract_eq(a, {:bigint, _} = b) when is_boolean(a),
    do: abstract_eq(Coercion.to_number(a), b)

  def abstract_eq({:bigint, _} = a, {:obj, _} = b), do: abstract_eq(a, Coercion.to_primitive(b))
  def abstract_eq({:obj, _} = a, {:bigint, _} = b), do: abstract_eq(Coercion.to_primitive(a), b)

  def abstract_eq({:obj, _} = obj, b) when is_number(b) or is_binary(b) do
    prim = Coercion.to_primitive(obj)

    if is_map(prim) or (is_tuple(prim) and elem(prim, 0) == :obj),
      do: false,
      else: abstract_eq(prim, b)
  end

  def abstract_eq(a, {:obj, _} = obj) when is_number(a) or is_binary(a) do
    prim = Coercion.to_primitive(obj)

    if is_map(prim) or (is_tuple(prim) and elem(prim, 0) == :obj),
      do: false,
      else: abstract_eq(a, prim)
  end

  def abstract_eq({:symbol, _} = a, {:obj, _} = b), do: abstract_eq(a, Coercion.to_primitive(b))
  def abstract_eq({:obj, _} = a, {:symbol, _} = b), do: abstract_eq(Coercion.to_primitive(a), b)

  def abstract_eq({:symbol, _, _} = a, {:obj, _} = b),
    do: abstract_eq(a, Coercion.to_primitive(b))

  def abstract_eq({:obj, _} = a, {:symbol, _, _} = b),
    do: abstract_eq(Coercion.to_primitive(a), b)

  def abstract_eq({:obj, ref1}, {:obj, ref2}), do: ref1 === ref2
  def abstract_eq({:symbol, _, ref1}, {:symbol, _, ref2}), do: ref1 === ref2
  def abstract_eq({:symbol, a}, {:symbol, b}), do: a === b
  def abstract_eq(_, _), do: false
end
