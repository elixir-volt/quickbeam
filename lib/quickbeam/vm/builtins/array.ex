defmodule QuickBEAM.VM.Builtins.Array do
  @moduledoc "Defines declarative additions to the core `Array` constructor."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Properties, Reference}

  builtin "Array", kind: :extension do
    static("isArray", :is_array, length: 1)

    prototype do
      method("filter", :filter, length: 1)
      method("forEach", :for_each, length: 1)
      method("map", :map, length: 1)
      method("reduce", :reduce, length: 1)
      method("some", :some, length: 1)
    end
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

  @doc "Plans resumable `Array.prototype.filter` iteration."
  def filter(%Call{} = call), do: iteration_action("filter", call)

  @doc "Plans resumable `Array.prototype.forEach` iteration."
  def for_each(%Call{} = call), do: iteration_action("forEach", call)

  @doc "Plans resumable `Array.prototype.map` iteration."
  def map(%Call{} = call), do: iteration_action("map", call)

  @doc "Plans resumable `Array.prototype.reduce` iteration."
  def reduce(%Call{} = call), do: iteration_action("reduce", call)

  @doc "Plans resumable `Array.prototype.some` iteration."
  def some(%Call{} = call), do: iteration_action("some", call)

  defp iteration_action(method, %Call{
         arguments: arguments,
         this: receiver,
         caller: caller,
         tail?: tail?,
         execution: execution
       }) do
    {:action, {:array_iteration, method, receiver, arguments, caller, execution, tail?}}
  end
end
