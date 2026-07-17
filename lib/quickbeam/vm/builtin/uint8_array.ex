defmodule QuickBEAM.VM.Builtin.Uint8Array do
  @moduledoc "Defines the minimal Uint8Array constructor required by server bundles."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Property

  builtin "Uint8Array",
    kind: :constructor,
    constructor: :construct,
    length: 3,
    depends_on: ["Object", "Function"] do
    prototype extends: "Object"
  end

  @doc "Constructs a byte array from a length or a list of numeric values."
  def construct(%Call{arguments: arguments, execution: execution}) do
    values =
      case arguments do
        [length | _] when is_integer(length) and length >= 0 -> List.duplicate(0, length)
        [values | _] when is_list(values) -> Enum.map(values, &normalize_byte/1)
        _arguments -> []
      end

    {array, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Property.define(array, index, value, execution)
        execution
      end)

    {:ok, array, execution}
  end

  defp normalize_byte(value) when is_number(value), do: trunc(value) |> Integer.mod(256)
  defp normalize_byte(_value), do: 0
end
