defmodule QuickBEAM.VM.Builtin.Boolean do
  @moduledoc "Defines declarative Boolean call and construction semantics."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.Value

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
        caller: %Boundary.Constructor{},
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
