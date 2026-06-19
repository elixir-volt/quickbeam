defmodule QuickBEAM.VM.Runtime.TypedArray.Metadata do
  @moduledoc "TypedArray constructor names, element types, and byte widths."

  @types %{
    "Uint8Array" => :uint8,
    "Int8Array" => :int8,
    "Uint8ClampedArray" => :uint8_clamped,
    "Uint16Array" => :uint16,
    "Int16Array" => :int16,
    "Uint32Array" => :uint32,
    "Int32Array" => :int32,
    "Float32Array" => :float32,
    "Float64Array" => :float64,
    "Float16Array" => :float16,
    "BigInt64Array" => :bigint64,
    "BigUint64Array" => :biguint64
  }

  def types, do: @types

  def constructor_type(name) when is_binary(name), do: Map.get(@types, name)
  def constructor_type(_), do: nil

  def elem_size(:uint8), do: 1
  def elem_size(:int8), do: 1
  def elem_size(:uint8_clamped), do: 1
  def elem_size(:uint16), do: 2
  def elem_size(:int16), do: 2
  def elem_size(:uint32), do: 4
  def elem_size(:int32), do: 4
  def elem_size(:float16), do: 2
  def elem_size(:float32), do: 4
  def elem_size(:float64), do: 8
  def elem_size(:bigint64), do: 8
  def elem_size(:biguint64), do: 8

  def name(type) do
    @types
    |> Enum.find_value(fn {name, candidate} -> if candidate == type, do: name end)
    |> Kernel.||("TypedArray")
  end
end
