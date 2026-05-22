defmodule QuickBEAM.VM.Runtime.Boolean do
  @moduledoc "JavaScript `Boolean` constructor and prototype builtins."

  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.InstallerHelpers

  builtin_definition("Boolean",
    constructor: constructor(),
    length: 1,
    phase: :fundamental,
    after_install: &__MODULE__.install_builtin/2
  )

  def install_builtin(ctor, opts \\ []) do
    object_proto = Keyword.get(opts, :object_proto, Heap.get_object_prototype())

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref, object_proto)
      Heap.put_obj_key(proto_ref, WrappedPrimitive.slot(:boolean), false)
      InstallerHelpers.install_methods(proto_ref, __MODULE__, ~w(toString valueOf))
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end

  proto "toString" do
    Atom.to_string(unwrap_boolean(this))
  end

  proto "valueOf" do
    unwrap_boolean(this)
  end

  defp unwrap_boolean({:obj, ref}) do
    case Heap.get_obj(ref, %{}) |> WrappedPrimitive.value(:boolean) do
      {:ok, value} -> value
      :error -> JSThrow.type_error!("Boolean method called on incompatible receiver")
    end
  end

  defp unwrap_boolean(value) when is_boolean(value), do: value

  defp unwrap_boolean(_value),
    do: JSThrow.type_error!("Boolean method called on incompatible receiver")

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn
      args, {:obj, _} = this ->
        val = args |> arg(0, false) |> Runtime.truthy?()
        InternalMethods.set(this, WrappedPrimitive.slot(:boolean), val)
        this

      args, _ ->
        args |> arg(0, false) |> Runtime.truthy?()
    end
  end
end
