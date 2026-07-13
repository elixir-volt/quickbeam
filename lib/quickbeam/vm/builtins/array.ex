defmodule QuickBEAM.VM.Builtins.Array do
  @moduledoc "Defines declarative additions to the core `Array` constructor."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Properties, Reference}

  builtin "Array", kind: :extension do
    static("isArray", :is_array, length: 1)
  end

  @doc "Implements `Array.isArray`."
  def is_array(%Call{arguments: arguments, execution: execution}) do
    value = List.first(arguments, :undefined)

    result =
      case value do
        %Reference{} = reference -> Properties.kind(reference, execution) == :array
        value -> is_list(value)
      end

    {:ok, result, execution}
  end
end
