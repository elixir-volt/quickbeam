defmodule QuickBEAM.VM.Interpreter.Values do
  @moduledoc "JS type coercion, arithmetic, comparison, and equality operations."

  alias QuickBEAM.VM.{Heap, Bytecode}
  alias QuickBEAM.VM.Interpreter.Values.{Arithmetic, Bitwise, Coercion, Comparison, Equality}

  import QuickBEAM.VM.Value, only: [is_object: 1]

  @compile {:inline,
            truthy?: 1,
            falsy?: 1,
            to_int32: 1,
            strict_eq: 2,
            add: 2,
            sub: 2,
            mul: 2,
            neg: 1,
            typeof: 1,
            to_number: 1,
            stringify: 1,
            lt: 2,
            lte: 2,
            gt: 2,
            gte: 2,
            eq: 2,
            neq: 2,
            band: 2,
            bor: 2,
            bxor: 2,
            shl: 2,
            sar: 2,
            shr: 2}

  alias QuickBEAM.VM.Bytecode

  # --- Truthiness ---

  def truthy?(nil), do: false
  def truthy?(:undefined), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(-0.0), do: false
  def truthy?(:nan), do: false
  def truthy?(""), do: false
  def truthy?({:bigint, 0}), do: false
  def truthy?({:bigint, _}), do: true
  def truthy?(_), do: true

  def falsy?(val), do: not truthy?(val)

  # --- Type query ---

  def typeof(:undefined), do: "undefined"
  def typeof(:nan), do: "number"
  def typeof(:infinity), do: "number"
  def typeof(:neg_infinity), do: "number"
  def typeof(nil), do: "object"
  def typeof(true), do: "boolean"
  def typeof(false), do: "boolean"
  def typeof(val) when is_number(val), do: "number"
  def typeof(val) when is_binary(val), do: "string"
  def typeof(%Bytecode.Function{}), do: "function"
  def typeof({:closure, _, %Bytecode.Function{}}), do: "function"
  def typeof({:symbol, _}), do: "symbol"
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:bound, _, _, _, _}), do: "function"
  def typeof({:bigint, _}), do: "bigint"
  def typeof({:builtin, _, map}) when is_map(map), do: "object"
  def typeof({:builtin, _, _}), do: "function"

  def typeof({:obj, ref}) do
    case Heap.get_obj(ref) do
      %{"__proxy_target__" => target} -> typeof(target)
      _ -> "object"
    end
  end

  def typeof(_), do: "object"

  # --- Hot coercion (kept inline) ---

  def to_number(val) when is_number(val), do: val
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: 0
  def to_number(:undefined), do: :nan
  def to_number(:infinity), do: :infinity
  def to_number(:neg_infinity), do: :neg_infinity
  def to_number(:nan), do: :nan
  def to_number(s) when is_binary(s), do: Coercion.parse_numeric(String.trim(s))

  def to_number({:bigint, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")}
      )

  def to_number({:obj, _} = obj) do
    prim = Coercion.to_primitive(obj)
    if is_object(prim), do: :nan, else: to_number(prim)
  end

  def to_number({:symbol, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def to_number({:symbol, _, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def to_number({:closure, _, _} = f), do: to_number(Coercion.fn_to_primitive(f))
  def to_number(%Bytecode.Function{} = f), do: to_number(Coercion.fn_to_primitive(f))
  def to_number({:bound, _, _, _, _} = f), do: to_number(Coercion.fn_to_primitive(f))
  def to_number({:builtin, _, _} = f), do: to_number(Coercion.fn_to_primitive(f))
  def to_number(_), do: :nan

  def to_int32(val), do: Coercion.to_int32(val)
  def to_uint32(val), do: Coercion.to_uint32(val)

  # --- Hot stringify (kept inline) ---

  def stringify(:undefined), do: "undefined"
  def stringify(nil), do: "null"
  def stringify(true), do: "true"
  def stringify(false), do: "false"
  def stringify(:nan), do: "NaN"
  def stringify(:infinity), do: "Infinity"
  def stringify(:neg_infinity), do: "-Infinity"
  def stringify(n) when is_integer(n), do: Integer.to_string(n)
  def stringify(n) when is_float(n) and n == 0.0, do: "0"
  def stringify(s) when is_binary(s), do: s
  def stringify(val), do: Coercion.to_string_val(val)

  # --- Arithmetic (delegated) ---

  defdelegate add(a, b), to: Arithmetic
  defdelegate sub(a, b), to: Arithmetic
  defdelegate mul(a, b), to: Arithmetic
  defdelegate js_div(a, b), to: Arithmetic
  defdelegate mod(a, b), to: Arithmetic
  defdelegate pow(a, b), to: Arithmetic
  defdelegate neg(a), to: Arithmetic
  def div(a, b), do: Arithmetic.js_div(a, b)

  # --- Comparisons (delegated) ---

  defdelegate lt(a, b), to: Comparison
  defdelegate lte(a, b), to: Comparison
  defdelegate gt(a, b), to: Comparison
  defdelegate gte(a, b), to: Comparison

  # --- Equality (delegated) ---

  defdelegate strict_eq(a, b), to: Equality
  defdelegate eq(a, b), to: Equality
  defdelegate neq(a, b), to: Equality
  defdelegate abstract_eq(a, b), to: Equality

  # --- Bitwise (delegated) ---

  defdelegate band(a, b), to: Bitwise
  defdelegate bor(a, b), to: Bitwise
  defdelegate bxor(a, b), to: Bitwise
  defdelegate bnot(a), to: Bitwise
  defdelegate shl(a, b), to: Bitwise
  defdelegate sar(a, b), to: Bitwise
  defdelegate shr(a, b), to: Bitwise
  defdelegate neg_zero?(val), to: Arithmetic
end
