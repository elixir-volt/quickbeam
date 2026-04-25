defmodule QuickBEAM.VM.Interpreter.Values.Arithmetic do
  @moduledoc "JS arithmetic operations: add, sub, mul, js_div, mod, pow, neg, and overflow helpers."

  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Bytecode, Heap, JSThrow}
  alias QuickBEAM.VM.Interpreter.Values.Coercion

  def add({:bigint, a}, {:bigint, b}), do: {:bigint, a + b}

  def add({:symbol, _}, _),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add(_, {:symbol, _}),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add({:symbol, _, _}, _),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add(_, {:symbol, _, _}),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add(a, b) when is_binary(a) and is_binary(b), do: a <> b
  def add(a, b) when is_binary(a) and is_number(b), do: a <> Coercion.to_string_val(b)
  def add(a, b) when is_number(a) and is_binary(b), do: Coercion.to_string_val(a) <> b

  def add(a, b) when is_binary(b) and not is_tuple(a) and not is_map(a),
    do: Coercion.to_string_val(a) <> b

  def add(a, b) when is_binary(a) and not is_tuple(b) and not is_map(b),
    do: a <> Coercion.to_string_val(b)

  def add(a, b) when is_number(a) and is_number(b), do: safe_add(a, b)

  def add({:obj, _} = a, b) do
    pa = Coercion.to_primitive(a)
    pb = if is_object(b), do: Coercion.to_primitive(b), else: b

    if is_object(pa) or is_object(pb) do
      Coercion.to_string_val(pa) <> Coercion.to_string_val(pb)
    else
      add(pa, pb)
    end
  end

  def add(a, {:obj, _} = b) do
    pb = Coercion.to_primitive(b)

    if is_object(pb) do
      Coercion.to_string_val(a) <> Coercion.to_string_val(pb)
    else
      add(a, pb)
    end
  end

  def add({:bigint, _} = a, b) when is_binary(b), do: Coercion.to_string_val(a) <> b
  def add(a, {:bigint, _} = b) when is_binary(a), do: a <> Coercion.to_string_val(b)
  def add({:bigint, _}, _), do: throw_bigint_mix_error()
  def add(_, {:bigint, _}), do: throw_bigint_mix_error()
  def add({:closure, _, _} = a, b), do: add(Coercion.fn_to_primitive(a), b)
  def add(a, {:closure, _, _} = b), do: add(a, Coercion.fn_to_primitive(b))
  def add(%Bytecode.Function{} = a, b), do: add(Coercion.fn_to_primitive(a), b)
  def add(a, %Bytecode.Function{} = b), do: add(a, Coercion.fn_to_primitive(b))
  def add({:bound, _, _, _, _} = a, b), do: add(Coercion.fn_to_primitive(a), b)
  def add(a, {:bound, _, _, _, _} = b), do: add(a, Coercion.fn_to_primitive(b))
  def add({:builtin, _, _} = a, b), do: add(Coercion.fn_to_primitive(a), b)
  def add(a, {:builtin, _, _} = b), do: add(a, Coercion.fn_to_primitive(b))
  def add(a, b), do: numeric_add(Coercion.to_number(a), Coercion.to_number(b))

  defp numeric_add(a, b) when is_number(a) and is_number(b), do: safe_add(a, b)
  defp numeric_add(:nan, _), do: :nan
  defp numeric_add(_, :nan), do: :nan
  defp numeric_add(:infinity, :neg_infinity), do: :nan
  defp numeric_add(:neg_infinity, :infinity), do: :nan
  defp numeric_add(:infinity, _), do: :infinity
  defp numeric_add(:neg_infinity, _), do: :neg_infinity
  defp numeric_add(_, :infinity), do: :infinity
  defp numeric_add(_, :neg_infinity), do: :neg_infinity
  defp numeric_add(_, _), do: :nan

  def sub({:bigint, a}, {:bigint, b}), do: {:bigint, a - b}
  def sub({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def sub(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def sub({:obj, _} = a, b), do: sub(Coercion.to_numeric(a), b)
  def sub(a, {:obj, _} = b), do: sub(a, Coercion.to_numeric(b))
  def sub({:bigint, _}, _), do: throw_bigint_mix_error()
  def sub(_, {:bigint, _}), do: throw_bigint_mix_error()

  def sub(a, b) when is_number(a) and is_number(b) do
    result = safe_add(a, -b)
    if result == 0 and neg_sign?(a) and not neg_sign?(b), do: -0.0, else: result
  end

  def sub(a, b), do: numeric_add(Coercion.to_number(a), neg(Coercion.to_number(b)))

  def mul({:bigint, a}, {:bigint, b}), do: {:bigint, a * b}
  def mul({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def mul(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def mul({:obj, _} = a, b), do: mul(Coercion.to_numeric(a), b)
  def mul(a, {:obj, _} = b), do: mul(a, Coercion.to_numeric(b))
  def mul({:bigint, _}, _), do: throw_bigint_mix_error()
  def mul(_, {:bigint, _}), do: throw_bigint_mix_error()
  def mul(a, b) when is_number(a) and is_number(b), do: safe_mul(a, b)

  def mul(a, b) do
    na = Coercion.to_number(a)
    nb = Coercion.to_number(b)

    cond do
      na == :nan or nb == :nan ->
        :nan

      na in [:infinity, :neg_infinity] or nb in [:infinity, :neg_infinity] ->
        if na == 0 or nb == 0, do: :nan, else: mul_inf_sign(na, nb)

      is_number(na) and is_number(nb) ->
        na * nb

      true ->
        :nan
    end
  end

  defp mul_inf_sign(a, b) do
    sign_a = if a == :neg_infinity or (is_number(a) and a < 0), do: -1, else: 1
    sign_b = if b == :neg_infinity or (is_number(b) and b < 0), do: -1, else: 1
    if sign_a * sign_b > 0, do: :infinity, else: :neg_infinity
  end

  def js_div({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, Kernel.div(a, b)}

  def js_div({:bigint, _}, {:bigint, 0}),
    do: JSThrow.range_error!("Division by zero")

  def js_div({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def js_div(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def js_div({:obj, _} = a, b), do: js_div(Coercion.to_numeric(a), b)
  def js_div(a, {:obj, _} = b), do: js_div(a, Coercion.to_numeric(b))
  def js_div({:bigint, _}, _), do: throw_bigint_mix_error()
  def js_div(_, {:bigint, _}), do: throw_bigint_mix_error()
  def js_div(a, b) when is_number(a) and is_number(b), do: div_numbers(a, b)

  def js_div(a, b) do
    na = Coercion.to_number(a)
    nb = Coercion.to_number(b)

    cond do
      na == :nan or nb == :nan ->
        :nan

      na in [:infinity, :neg_infinity] or nb in [:infinity, :neg_infinity] ->
        div_inf(na, nb)

      is_number(na) and is_number(nb) ->
        div_numbers(na, nb)

      true ->
        :nan
    end
  end

  defp div_inf(:infinity, :infinity), do: :nan
  defp div_inf(:infinity, :neg_infinity), do: :nan
  defp div_inf(:neg_infinity, :infinity), do: :nan
  defp div_inf(:neg_infinity, :neg_infinity), do: :nan

  defp div_inf(:infinity, n) when is_number(n),
    do: if(neg_sign?(n), do: :neg_infinity, else: :infinity)

  defp div_inf(:neg_infinity, n) when is_number(n),
    do: if(neg_sign?(n), do: :infinity, else: :neg_infinity)

  defp div_inf(n, :infinity) when is_number(n), do: if(n < 0, do: -0.0, else: 0.0)
  defp div_inf(n, :neg_infinity) when is_number(n), do: if(n < 0, do: 0.0, else: -0.0)
  defp div_inf(_, _), do: :nan

  defp div_numbers(a, b) when b == 0,
    do: if(neg_zero?(b), do: div_by_neg_zero(a), else: inf_or_nan(a))

  defp div_numbers(a, b) do
    try do
      a / b
    rescue
      ArithmeticError ->
        if (a > 0 and b > 0) or (a < 0 and b < 0), do: :infinity, else: :neg_infinity
    end
  end

  defp div_by_neg_zero(a) when a > 0, do: :neg_infinity
  defp div_by_neg_zero(a) when a < 0, do: :infinity
  defp div_by_neg_zero(_), do: :nan

  def mod({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, rem(a, b)}

  def mod({:bigint, _}, {:bigint, 0}),
    do: JSThrow.range_error!("Division by zero")

  def mod({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def mod(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def mod({:obj, _} = a, b), do: mod(Coercion.to_numeric(a), b)
  def mod(a, {:obj, _} = b), do: mod(a, Coercion.to_numeric(b))
  def mod({:bigint, _}, _), do: throw_bigint_mix_error()
  def mod(_, {:bigint, _}), do: throw_bigint_mix_error()

  def mod(a, b) when is_integer(a) and is_integer(b) and b != 0 do
    case rem(a, b) do
      0 when a < 0 -> -0.0
      r -> r
    end
  end

  def mod(a, b) when is_number(a) and is_number(b) and b != 0 do
    result = :math.fmod(a / 1, b / 1)
    if result == 0 and neg_sign?(a), do: -0.0, else: result
  end

  def mod(a, b) when is_number(a) and is_number(b), do: :nan
  def mod(a, b), do: numeric_mod(Coercion.to_number(a), Coercion.to_number(b))

  defp numeric_mod(:nan, _), do: :nan
  defp numeric_mod(_, :nan), do: :nan
  defp numeric_mod(:infinity, _), do: :nan
  defp numeric_mod(:neg_infinity, _), do: :nan
  defp numeric_mod(a, :infinity) when is_number(a), do: a
  defp numeric_mod(a, :neg_infinity) when is_number(a), do: a
  defp numeric_mod(_, b) when is_number(b) and b == 0, do: :nan
  defp numeric_mod(a, b) when is_integer(a) and is_integer(b), do: rem(a, b)

  defp numeric_mod(a, b) when is_number(a) and is_number(b) do
    try do
      a - Float.floor(a / b) * b
    rescue
      ArithmeticError -> :nan
    end
  end

  defp numeric_mod(_, _), do: :nan

  def pow({:bigint, a}, {:bigint, b}) when b >= 0, do: {:bigint, Integer.pow(a, b)}
  def pow(a, b) when is_number(a) and is_number(b), do: :math.pow(a, b)
  def pow(_, _), do: :nan

  def neg({:bigint, a}), do: {:bigint, -a}
  def neg(0), do: -0.0
  def neg(:infinity), do: :neg_infinity
  def neg(:neg_infinity), do: :infinity
  def neg(:nan), do: :nan
  def neg(a) when is_number(a), do: -a

  def neg({:obj, _} = a) do
    case Coercion.to_primitive(a) do
      {:bigint, _} = b -> neg(b)
      other -> neg(Coercion.to_number(other))
    end
  end

  def neg(a), do: neg(Coercion.to_number(a))

  def safe_add(a, b) do
    try do
      a + b
    rescue
      ArithmeticError ->
        if a > 0 or b > 0, do: :infinity, else: :neg_infinity
    end
  end

  def safe_mul(a, b) do
    try do
      a * b
    rescue
      ArithmeticError ->
        if (a > 0 and b > 0) or (a < 0 and b < 0), do: :infinity, else: :neg_infinity
    end
  end

  def neg_zero?(b), do: is_float(b) and b == 0.0 and hd(:erlang.float_to_list(b)) == ?-

  defp neg_sign?(n), do: n < 0 or neg_zero?(n)

  defp inf_or_nan(a) when a > 0, do: :infinity
  defp inf_or_nan(a) when a < 0, do: :neg_infinity
  defp inf_or_nan(_), do: :nan

  defp throw_bigint_mix_error do
    throw(
      {:js_throw,
       Heap.make_error("Cannot mix BigInt and other types, use explicit conversions", "TypeError")}
    )
  end
end
