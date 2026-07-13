defmodule QuickBEAM.VM.Builtins.Boolean do
  @moduledoc "Defines declarative Boolean call and construction semantics."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{ConstructorBoundary, Heap, Reference, Value}

  builtin "Boolean",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function"] do
    prototype extends: "Object", primitive: {:boolean, false}
  end

  @doc "Converts a value to boolean or initializes a boxed Boolean."
  def construct(%Call{
        this: %Reference{} = receiver,
        caller: %ConstructorBoundary{},
        arguments: arguments,
        execution: execution
      }) do
    value = arguments |> List.first(:undefined) |> Value.truthy?()

    {:ok, execution} =
      Heap.update_object(execution, receiver, fn object ->
        %{object | internal: {:primitive, :boolean, value}}
      end)

    {:ok, receiver, execution}
  end

  def construct(%Call{arguments: arguments, execution: execution}) do
    value = arguments |> List.first(:undefined) |> Value.truthy?()
    {:ok, value, execution}
  end
end
