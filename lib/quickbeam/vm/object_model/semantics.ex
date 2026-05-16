defmodule QuickBEAM.VM.ObjectModel.Semantics do
  @moduledoc "Shared object-model semantic helpers."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime

  def same_value?(a, b) when is_number(a) and is_number(b) and a == 0 and b == 0,
    do: Values.neg_zero?(a) == Values.neg_zero?(b)

  def same_value?(a, b) when is_number(a) and is_number(b), do: a === b
  def same_value?(:nan, :nan), do: true
  def same_value?(a, b), do: a === b

  def strict_mode? do
    case Heap.get_ctx() do
      %{current_func: {:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}} -> true
      %{current_func: %QuickBEAM.VM.Function{is_strict_mode: true}} -> true
      _ -> false
    end
  end

  def descriptor_attrs(desc_obj, desc, existing_attrs, default) do
    PropertyDescriptor.attrs(
      writable: PropertyDescriptor.attribute(desc_obj, desc, "writable", existing_attrs, default),
      enumerable:
        PropertyDescriptor.attribute(desc_obj, desc, "enumerable", existing_attrs, default),
      configurable:
        PropertyDescriptor.attribute(desc_obj, desc, "configurable", existing_attrs, default)
    )
  end

  def enumerable_array_keys(ref, arr, side_keys) do
    (side_keys ++
       (arr
        |> :array.sparse_to_orddict()
        |> Enum.map(fn {index, _value} -> Integer.to_string(index) end)
        |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)))
    |> Runtime.sort_numeric_keys()
  end
end
