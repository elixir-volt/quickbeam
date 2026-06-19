defmodule QuickBEAM.VM.Runtime.Atomics do
  @moduledoc "JavaScript `Atomics` object for typed-array operations."

  use QuickBEAM.VM.Builtin

  import Bitwise

  alias QuickBEAM.VM.{Builtin, Heap, JSThrow}
  alias QuickBEAM.VM.Runtime.TypedArray
  alias QuickBEAM.VM.Runtime.TypedArrayCoercion

  @method_lengths %{
    "add" => 3,
    "and" => 3,
    "compareExchange" => 4,
    "exchange" => 3,
    "isLockFree" => 1,
    "load" => 2,
    "notify" => 3,
    "or" => 3,
    "pause" => 0,
    "store" => 3,
    "sub" => 3,
    "wait" => 4,
    "xor" => 3
  }

  def install_metadata({:builtin, _name, map} = atomics) when is_map(map) do
    Builtin.install_object_metadata(atomics, @method_lengths, to_string_tag: "Atomics")
  end

  js_object "Atomics" do
    method "add" do
      read_modify_write(args, &+/2)
    end

    method "and" do
      read_modify_write(args, fn left, right -> left &&& right end)
    end

    method "compareExchange" do
      compare_exchange(args)
    end

    method "exchange" do
      exchange(args)
    end

    method "isLockFree" do
      size = args |> Builtin.arg(0, :undefined) |> TypedArrayCoercion.integer_or_infinity()
      if size in [1, 2, 4, 8], do: true, else: false
    end

    method "load" do
      {typed_array, index, _type} = validate_access(args)
      TypedArray.get_element(typed_array, index)
    end

    method "notify" do
      notify(args)
    end

    method "or" do
      read_modify_write(args, fn left, right -> left ||| right end)
    end

    method "pause" do
      pause(args)
    end

    method "store" do
      {typed_array, index, type} = validate_access(args)
      value = storage_value(Builtin.arg(args, 2, :undefined), type)
      TypedArray.set_element(typed_array, index, normalized_value(value, type))
      value
    end

    method "sub" do
      read_modify_write(args, &-/2)
    end

    method "wait" do
      wait(args)
    end

    method "xor" do
      read_modify_write(args, fn left, right -> bxor(left, right) end)
    end
  end

  defp read_modify_write(args, operation) do
    {typed_array, index, type} = validate_access(args)
    value = normalized_value(Builtin.arg(args, 2, :undefined), type)
    old = TypedArray.get_element(typed_array, index)
    result = apply_operation(old, value, type, operation)
    TypedArray.set_element(typed_array, index, result)
    old
  end

  defp exchange(args) do
    {typed_array, index, type} = validate_access(args)
    value = normalized_value(Builtin.arg(args, 2, :undefined), type)
    old = TypedArray.get_element(typed_array, index)
    TypedArray.set_element(typed_array, index, value)
    old
  end

  defp compare_exchange(args) do
    {typed_array, index, type} = validate_access(args)
    expected = normalized_value(Builtin.arg(args, 2, :undefined), type)
    replacement = normalized_value(Builtin.arg(args, 3, :undefined), type)
    old = TypedArray.get_element(typed_array, index)

    if same_numeric_value?(old, expected, type) do
      TypedArray.set_element(typed_array, index, replacement)
    end

    old
  end

  defp notify(args) do
    {_typed_array, _index, _type} = validate_notify_access(args)
    _count = args |> Builtin.arg(2, :infinity) |> TypedArrayCoercion.integer_or_infinity()
    0
  end

  defp wait(args) do
    {typed_array, index, type} = validate_waitable_access(args)
    expected = normalized_value(Builtin.arg(args, 2, :undefined), type)
    _timeout = args |> Builtin.arg(3, :infinity) |> TypedArrayCoercion.integer_or_infinity()

    unless TypedArray.shared_buffer?(typed_array) do
      JSThrow.type_error!("Atomics.wait requires SharedArrayBuffer")
    end

    cond do
      not same_numeric_value?(TypedArray.get_element(typed_array, index), expected, type) ->
        "not-equal"

      true ->
        JSThrow.type_error!("Atomics.wait cannot suspend")
    end
  end

  defp pause(args) do
    case Builtin.arg(args, 0, :undefined) do
      :undefined -> :undefined
      value when is_integer(value) and value >= 0 -> :undefined
      value when is_float(value) and value >= 0 and floor(value) == value -> :undefined
      _ -> JSThrow.type_error!("invalid iterationNumber")
    end
  end

  defp validate_access(args) do
    typed_array = validate_integer_typed_array!(Builtin.arg(args, 0, :undefined))
    type = TypedArray.element_type(typed_array)
    index = args |> Builtin.arg(1, :undefined) |> TypedArrayCoercion.index()

    if TypedArray.out_of_bounds?(typed_array) or index >= TypedArray.element_count(typed_array) do
      JSThrow.range_error!("Invalid atomic access index")
    end

    {typed_array, index, type}
  end

  defp validate_notify_access(args) do
    typed_array = validate_integer_typed_array!(Builtin.arg(args, 0, :undefined))
    type = TypedArray.element_type(typed_array)

    unless type in [:int32, :bigint64] do
      JSThrow.type_error!("Atomics notify requires Int32Array or BigInt64Array")
    end

    index = args |> Builtin.arg(1, :undefined) |> TypedArrayCoercion.index()

    if TypedArray.out_of_bounds?(typed_array) or index >= TypedArray.element_count(typed_array) do
      JSThrow.range_error!("Invalid atomic access index")
    end

    {typed_array, index, type}
  end

  defp validate_waitable_access(args) do
    typed_array = validate_integer_typed_array!(Builtin.arg(args, 0, :undefined))
    type = TypedArray.element_type(typed_array)

    unless type in [:int32, :bigint64] do
      JSThrow.type_error!("Atomics wait/notify requires Int32Array or BigInt64Array")
    end

    unless TypedArray.shared_buffer?(typed_array) do
      JSThrow.type_error!("Atomics.wait requires SharedArrayBuffer")
    end

    index = args |> Builtin.arg(1, :undefined) |> TypedArrayCoercion.index()

    if TypedArray.out_of_bounds?(typed_array) or index >= TypedArray.element_count(typed_array) do
      JSThrow.range_error!("Invalid atomic access index")
    end

    {typed_array, index, type}
  end

  defp validate_integer_typed_array!({:obj, ref} = value) do
    unless Map.get(Heap.get_obj(ref, %{}), "__typed_array__") do
      JSThrow.type_error!("Atomics operation requires an integer typed array")
    end

    type = TypedArray.element_type(value)

    if atomics_friendly_type?(type) do
      value
    else
      JSThrow.type_error!("Atomics operation requires an integer typed array")
    end
  rescue
    _ -> JSThrow.type_error!("Atomics operation requires an integer typed array")
  catch
    {:js_throw, _} -> JSThrow.type_error!("Atomics operation requires an integer typed array")
  end

  defp validate_integer_typed_array!(_),
    do: JSThrow.type_error!("Atomics operation requires an integer typed array")

  defp atomics_friendly_type?(type),
    do: type in [:int8, :uint8, :int16, :uint16, :int32, :uint32, :bigint64, :biguint64]

  defp normalized_value(value, type), do: TypedArray.normalized_element(value, type)

  defp storage_value(value, type) when type in [:bigint64, :biguint64],
    do: TypedArrayCoercion.element_value(value, type)

  defp storage_value(value, _type), do: TypedArrayCoercion.integer_or_infinity(value)

  defp apply_operation({:bigint, left}, {:bigint, right}, type, operation)
       when type in [:bigint64, :biguint64] do
    {:bigint, operation.(left, right)}
  end

  defp apply_operation(left, right, _type, operation),
    do: operation.(integer_value(left), integer_value(right))

  defp integer_value(:nan), do: 0
  defp integer_value(:infinity), do: 0
  defp integer_value(:neg_infinity), do: 0
  defp integer_value({:bigint, value}), do: value
  defp integer_value(:undefined), do: 0
  defp integer_value(value) when is_number(value), do: trunc(value)

  defp same_numeric_value?({:bigint, left}, {:bigint, right}, type)
       when type in [:bigint64, :biguint64],
       do: left == right

  defp same_numeric_value?(left, right, _type), do: left == right
end
