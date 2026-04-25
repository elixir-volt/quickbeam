defmodule QuickBEAM.VM.Interpreter.Values.Comparison do
  @moduledoc "JS relational comparisons: lt, lte, gt, gte, numeric_compare, abstract_compare."

  import Bitwise

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values.Coercion

  def lt({:bigint, a}, {:bigint, b}), do: a < b
  def lt({:bigint, _}, :nan), do: false
  def lt(:nan, {:bigint, _}), do: false
  def lt({:bigint, _}, :infinity), do: true
  def lt({:bigint, _}, :neg_infinity), do: false
  def lt(:infinity, {:bigint, _}), do: false
  def lt(:neg_infinity, {:bigint, _}), do: true
  def lt({:bigint, a}, b) when is_number(b), do: a < b
  def lt(a, {:bigint, b}) when is_number(a), do: a < b
  def lt({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.</2)

  def lt(a, {:bigint, _} = b) when is_binary(a),
    do: bigint_string_compare(b, a, fn x, y -> y < x end)

  def lt({:bigint, a}, b) when is_boolean(b), do: a < Coercion.to_number(b)
  def lt(a, {:bigint, b}) when is_boolean(a), do: Coercion.to_number(a) < b

  def lt({:bigint, _}, {:symbol, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def lt({:bigint, _}, {:symbol, _, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def lt({:symbol, _}, {:bigint, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def lt({:symbol, _, _}, {:bigint, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def lt(a, b) when is_number(a) and is_number(b), do: a < b
  def lt(a, b) when is_binary(a) and is_binary(b), do: utf16_compare(a, b) == :lt

  def lt(a, b) do
    pa = Coercion.coerce_to_primitive(a)
    pb = Coercion.coerce_to_primitive(b)

    if is_binary(pa) and is_binary(pb),
      do: pa < pb,
      else: numeric_compare(Coercion.to_number(pa), Coercion.to_number(pb), &Kernel.</2)
  end

  def lte({:bigint, a}, {:bigint, b}), do: a <= b
  def lte({:bigint, _}, :nan), do: false
  def lte(:nan, {:bigint, _}), do: false
  def lte({:bigint, _}, :infinity), do: true
  def lte({:bigint, _}, :neg_infinity), do: false
  def lte(:infinity, {:bigint, _}), do: false
  def lte(:neg_infinity, {:bigint, _}), do: true
  def lte({:bigint, a}, b) when is_number(b), do: a <= b
  def lte(a, {:bigint, b}) when is_number(a), do: a <= b
  def lte({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.<=/2)
  def lte({:bigint, a}, b) when is_boolean(b), do: a <= Coercion.to_number(b)
  def lte(a, {:bigint, b}) when is_boolean(a), do: Coercion.to_number(a) <= b

  def lte(a, {:bigint, _} = b) when is_binary(a),
    do: bigint_string_compare(b, a, fn x, y -> y <= x end)

  def lte(a, b) when is_number(a) and is_number(b), do: a <= b
  def lte(a, b) when is_binary(a) and is_binary(b), do: utf16_compare(a, b) in [:lt, :eq]

  def lte(a, b) do
    pa = Coercion.coerce_to_primitive(a)
    pb = Coercion.coerce_to_primitive(b)

    if is_binary(pa) and is_binary(pb),
      do: pa <= pb,
      else: numeric_compare(Coercion.to_number(pa), Coercion.to_number(pb), &Kernel.<=/2)
  end

  def gt({:bigint, a}, {:bigint, b}), do: a > b
  def gt({:bigint, _}, :nan), do: false
  def gt(:nan, {:bigint, _}), do: false
  def gt({:bigint, _}, :infinity), do: false
  def gt({:bigint, _}, :neg_infinity), do: true
  def gt(:infinity, {:bigint, _}), do: true
  def gt(:neg_infinity, {:bigint, _}), do: false
  def gt({:bigint, a}, b) when is_number(b), do: a > b
  def gt(a, {:bigint, b}) when is_number(a), do: a > b
  def gt({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.>/2)
  def gt({:bigint, a}, b) when is_boolean(b), do: a > Coercion.to_number(b)
  def gt(a, {:bigint, b}) when is_boolean(a), do: Coercion.to_number(a) > b

  def gt(a, {:bigint, _} = b) when is_binary(a),
    do: bigint_string_compare(b, a, fn x, y -> y > x end)

  def gt({:bigint, _}, s) when is_tuple(s) and elem(s, 0) == :symbol,
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def gt(s, {:bigint, _}) when is_tuple(s) and elem(s, 0) == :symbol,
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def gt(a, b) when is_number(a) and is_number(b), do: a > b
  def gt(a, b) when is_binary(a) and is_binary(b), do: utf16_compare(a, b) == :gt

  def gt(a, b) do
    pa = Coercion.coerce_to_primitive(a)
    pb = Coercion.coerce_to_primitive(b)

    if is_binary(pa) and is_binary(pb),
      do: pa > pb,
      else: numeric_compare(Coercion.to_number(pa), Coercion.to_number(pb), &Kernel.>/2)
  end

  def gte({:bigint, a}, {:bigint, b}), do: a >= b
  def gte({:bigint, _}, :nan), do: false
  def gte(:nan, {:bigint, _}), do: false
  def gte({:bigint, _}, :infinity), do: false
  def gte({:bigint, _}, :neg_infinity), do: true
  def gte(:infinity, {:bigint, _}), do: true
  def gte(:neg_infinity, {:bigint, _}), do: false
  def gte({:bigint, a}, b) when is_number(b), do: a >= b
  def gte(a, {:bigint, b}) when is_number(a), do: a >= b
  def gte({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.>=/2)
  def gte({:bigint, a}, b) when is_boolean(b), do: a >= Coercion.to_number(b)
  def gte(a, {:bigint, b}) when is_boolean(a), do: Coercion.to_number(a) >= b

  def gte(a, {:bigint, _} = b) when is_binary(a),
    do: bigint_string_compare(b, a, fn x, y -> y >= x end)

  def gte({:bigint, _}, s) when is_tuple(s) and elem(s, 0) == :symbol,
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def gte(s, {:bigint, _}) when is_tuple(s) and elem(s, 0) == :symbol,
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def gte(a, b) when is_number(a) and is_number(b), do: a >= b
  def gte(a, b) when is_binary(a) and is_binary(b), do: utf16_compare(a, b) in [:gt, :eq]

  def gte(a, b) do
    pa = Coercion.coerce_to_primitive(a)
    pb = Coercion.coerce_to_primitive(b)

    if is_binary(pa) and is_binary(pb),
      do: pa >= pb,
      else: numeric_compare(Coercion.to_number(pa), Coercion.to_number(pb), &Kernel.>=/2)
  end

  def numeric_compare(:nan, _, _), do: false
  def numeric_compare(_, :nan, _), do: false
  def numeric_compare(:infinity, :infinity, op), do: op.(1, 1)
  def numeric_compare(:neg_infinity, :neg_infinity, op), do: op.(1, 1)
  def numeric_compare(:infinity, _, op), do: op.(1, 0)
  def numeric_compare(_, :infinity, op), do: op.(0, 1)
  def numeric_compare(:neg_infinity, _, op), do: op.(0, 1)
  def numeric_compare(_, :neg_infinity, op), do: op.(1, 0)
  def numeric_compare(a, b, op) when is_number(a) and is_number(b), do: op.(a, b)
  def numeric_compare(_, _, _), do: false

  defp bigint_string_compare({:bigint, a}, str, op) do
    trimmed = String.trim(str)

    case trimmed do
      "" ->
        op.(a, 0)

      "0x" <> hex ->
        case Integer.parse(hex, 16) do
          {n, ""} -> op.(a, n)
          _ -> false
        end

      "0X" <> hex ->
        case Integer.parse(hex, 16) do
          {n, ""} -> op.(a, n)
          _ -> false
        end

      "0o" <> oct ->
        case Integer.parse(oct, 8) do
          {n, ""} -> op.(a, n)
          _ -> false
        end

      "0b" <> bin ->
        case Integer.parse(bin, 2) do
          {n, ""} -> op.(a, n)
          _ -> false
        end

      _ ->
        case Integer.parse(trimmed) do
          {n, ""} -> op.(a, n)
          _ -> false
        end
    end
  end

  defp utf16_compare(a, b) when a == b, do: :eq

  defp utf16_compare(a, b) do
    if needs_utf16_compare?(a) or needs_utf16_compare?(b) do
      compare_utf16_units(to_utf16_units(a), to_utf16_units(b))
    else
      cond do
        a < b -> :lt
        a > b -> :gt
        true -> :eq
      end
    end
  end

  defp needs_utf16_compare?(<<>>), do: false
  defp needs_utf16_compare?(<<b, _::binary>>) when b >= 0xF0, do: true
  defp needs_utf16_compare?(<<b, _::binary>>) when b >= 0xED, do: true
  defp needs_utf16_compare?(<<_, rest::binary>>), do: needs_utf16_compare?(rest)

  defp to_utf16_units(<<>>), do: []

  defp to_utf16_units(<<cp::utf8, rest::binary>>) when cp >= 0x10000 do
    hi = 0xD800 + ((cp - 0x10000) >>> 10)
    lo = 0xDC00 + (cp - 0x10000 &&& 0x3FF)
    [hi, lo | to_utf16_units(rest)]
  end

  defp to_utf16_units(<<0xED, a, b, rest::binary>>) when a >= 0xA0 do
    cp = (0xED &&& 0x0F) <<< 12 ||| (a &&& 0x3F) <<< 6 ||| (b &&& 0x3F)
    [cp | to_utf16_units(rest)]
  end

  defp to_utf16_units(<<cp::utf8, rest::binary>>), do: [cp | to_utf16_units(rest)]
  defp to_utf16_units(<<_, rest::binary>>), do: to_utf16_units(rest)

  defp compare_utf16_units([], []), do: :eq
  defp compare_utf16_units([], _), do: :lt
  defp compare_utf16_units(_, []), do: :gt

  defp compare_utf16_units([a | ra], [b | rb]) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> compare_utf16_units(ra, rb)
    end
  end
end
