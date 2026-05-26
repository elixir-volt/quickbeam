defmodule QuickBEAM.VM.Runtime.BigInt do
  @moduledoc "JavaScript `BigInt` constructor installation metadata."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Semantics.Coercion

  defintrinsic "BigInt" do
    constructor(&QuickBEAM.VM.Runtime.ConstructorCallbacks.bigint/2,
      length: 1,
      phase: :fundamental
    )

    prototype extends: :object do
      slot(:BigIntData, {:bigint, 0})
      to_string_tag("BigInt")

      method "toString", length: 1, receiver: :bigint do
        {:bigint, value} = this
        bigint_to_string(value, args)
      end

      method "valueOf", receiver: :bigint do
        this
      end
    end

    install_with(&__MODULE__.install_builtin/2)
  end

  def install_builtin(ctor, _opts \\ []) do
    install_static_method(ctor, "asIntN", 2, &as_int_n/2)
    install_static_method(ctor, "asUintN", 2, &as_uint_n/2)
  end

  defp install_static_method(ctor, name, length, callback) do
    fun = {:builtin, name, callback}

    QuickBEAM.VM.Builtin.put_builtin_metadata(
      fun,
      QuickBEAM.VM.Builtin.meta(name, length: length)
    )

    QuickBEAM.VM.Builtin.put_function_metadata(fun, name, length)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_static(ctor, name, fun)
    Heap.put_ctor_prop_desc(ctor, name, PropertyDescriptor.method())
  end

  def as_int_n(args, _this) do
    bits = to_index(QuickBEAM.VM.Builtin.arg(args, 0, :undefined))
    {:bigint, value} = to_bigint(QuickBEAM.VM.Builtin.arg(args, 1, :undefined))
    {:bigint, truncate_bigint(bits, value, true)}
  end

  def as_uint_n(args, _this) do
    bits = to_index(QuickBEAM.VM.Builtin.arg(args, 0, :undefined))
    {:bigint, value} = to_bigint(QuickBEAM.VM.Builtin.arg(args, 1, :undefined))
    {:bigint, truncate_bigint(bits, value, false)}
  end

  def to_bigint({:bigint, _} = value), do: value
  def to_bigint(true), do: {:bigint, 1}
  def to_bigint(false), do: {:bigint, 0}

  def to_bigint(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_bigint_string()
    |> case do
      {:ok, int} -> {:bigint, int}
      :error -> JSThrow.syntax_error!("Cannot convert to BigInt")
    end
  end

  def to_bigint({:obj, _} = value), do: value |> Coercion.to_primitive("number") |> to_bigint()
  def to_bigint(_), do: JSThrow.type_error!("Cannot convert to BigInt")

  def parse_bigint_string(""), do: {:ok, 0}
  def parse_bigint_string("0x" <> digits), do: parse_bigint_digits(digits, 16)
  def parse_bigint_string("0X" <> digits), do: parse_bigint_digits(digits, 16)
  def parse_bigint_string("0o" <> digits), do: parse_bigint_digits(digits, 8)
  def parse_bigint_string("0O" <> digits), do: parse_bigint_digits(digits, 8)
  def parse_bigint_string("0b" <> digits), do: parse_bigint_digits(digits, 2)
  def parse_bigint_string("0B" <> digits), do: parse_bigint_digits(digits, 2)
  def parse_bigint_string("+" <> digits), do: parse_bigint_digits(digits, 10)

  def parse_bigint_string("-" <> digits) do
    case parse_bigint_digits(digits, 10) do
      {:ok, value} -> {:ok, -value}
      :error -> :error
    end
  end

  def parse_bigint_string(digits), do: parse_bigint_digits(digits, 10)

  defp parse_bigint_digits("", _base), do: :error

  defp parse_bigint_digits(digits, base) do
    case Integer.parse(digits, base) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp bigint_to_string(value, [:undefined | _]), do: Integer.to_string(value)
  defp bigint_to_string(value, []), do: Integer.to_string(value)

  defp bigint_to_string(value, [radix | _]) do
    radix = to_radix(radix)
    value |> Integer.to_string(radix) |> String.downcase()
  end

  defp to_radix(:undefined), do: 10

  defp to_radix({:bigint, _}),
    do: JSThrow.type_error!("Cannot convert a BigInt value to a number")

  defp to_radix({:obj, _} = value), do: value |> Coercion.to_primitive("number") |> to_radix()

  defp to_radix(value) do
    case Runtime.to_number(value) do
      n when n in [:nan, :undefined] -> 10
      n when is_integer(n) and n >= 2 and n <= 36 -> n
      n when is_float(n) and trunc(n) >= 2 and trunc(n) <= 36 -> trunc(n)
      _ -> JSThrow.range_error!("radix out of range")
    end
  end

  defp to_index({:bigint, _}),
    do: JSThrow.type_error!("Cannot convert a BigInt value to a number")

  defp to_index({:symbol, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a number")

  defp to_index({:symbol, _, _}),
    do: JSThrow.type_error!("Cannot convert a Symbol value to a number")

  defp to_index({:obj, _} = value),
    do: value |> Coercion.to_primitive("number") |> to_index()

  defp to_index(value) do
    case Runtime.to_number(value) do
      n when n in [:nan, :undefined] -> 0
      :infinity -> JSThrow.range_error!("Invalid index")
      :neg_infinity -> JSThrow.range_error!("Invalid index")
      n when is_integer(n) and n < 0 -> JSThrow.range_error!("Invalid index")
      n when is_float(n) and trunc(n) < 0 -> JSThrow.range_error!("Invalid index")
      n when is_number(n) and n > 9_007_199_254_740_991 -> JSThrow.range_error!("Invalid index")
      n when is_number(n) -> trunc(n)
      _ -> 0
    end
  end

  defp truncate_bigint(0, _value, _signed?), do: 0

  defp truncate_bigint(bits, value, signed?) do
    modulo = Integer.pow(2, bits)
    int = Integer.mod(value, modulo)

    if signed? and int >= Integer.pow(2, bits - 1), do: int - modulo, else: int
  end
end
