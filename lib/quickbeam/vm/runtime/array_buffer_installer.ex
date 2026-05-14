defmodule QuickBEAM.VM.Runtime.ArrayBufferInstaller do
  @moduledoc "Installs the ArrayBuffer constructor, prototype methods, and Symbol.species accessor."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime.ArrayBuffer
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry

  @doc "Returns the global ArrayBuffer constructor binding."
  def constructor do
    ctor =
      ConstructorRegistry.register("ArrayBuffer", &ArrayBuffer.constructor/2, auto_proto: true)

    install_prototype_methods(ctor)
    install_species(ctor)
    ctor
  end

  defp install_prototype_methods(ctor) do
    with_prototype(ctor, fn proto_ref ->
      for name <- ArrayBuffer.proto_property_names() do
        Heap.put_obj_key(proto_ref, name, ArrayBuffer.proto_property(name))
        Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.method())
      end
    end)
  end

  defp install_species(ctor) do
    Heap.put_ctor_static(
      ctor,
      {:symbol, "Symbol.species"},
      {:accessor, {:builtin, "get [Symbol.species]", fn _, _ -> ctor end}, nil}
    )
  end

  defp with_prototype(ctor, fun) do
    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} -> fun.(proto_ref)
      _ -> :ok
    end
  end
end
