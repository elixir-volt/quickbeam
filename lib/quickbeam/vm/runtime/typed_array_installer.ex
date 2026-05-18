defmodule QuickBEAM.VM.Runtime.TypedArrayInstaller do
  @moduledoc "Installs typed-array constructors and their shared abstract superclass."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.TypedArray

  @doc "Returns global bindings for all typed-array constructors."
  def bindings do
    ta_base = abstract_typed_array_constructor()
    install_base_prototype(ta_base)

    base_proto = Heap.get_class_proto(ta_base)

    for {name, type} <- TypedArray.types(), into: %{} do
      ctor =
        ConstructorRegistry.register(
          name,
          TypedArray.constructor(type),
          TypedArray.prototype_properties(),
          base_proto
        )

      mark_prototype_methods(ctor)
      install_static_methods(ctor)
      install_species(ctor)
      Heap.put_ctor_static(ctor, "__proto__", ta_base)
      Heap.put_ctor_static(ctor, "BYTES_PER_ELEMENT", TypedArray.elem_size(type))
      {name, ctor}
    end
  end

  defp abstract_typed_array_constructor do
    {:builtin, "TypedArray",
     fn _args, _this ->
       throw(
         {:js_throw, Heap.make_error("Abstract class TypedArray cannot be called", "TypeError")}
       )
     end}
  end

  defp install_base_prototype(ta_base) do
    ta_base_ref = make_ref()

    Heap.put_obj(
      ta_base_ref,
      Map.put(TypedArray.base_prototype_properties(), "__proto__", Heap.get_object_prototype())
    )

    Heap.put_prop_desc(ta_base_ref, "at", PropertyDescriptor.method())

    for key <- ["buffer", "byteLength", "byteOffset", {:symbol, "Symbol.toStringTag"}] do
      Heap.put_prop_desc(ta_base_ref, key, PropertyDescriptor.accessor())
    end

    ConstructorRegistry.put_prototype(ta_base, {:obj, ta_base_ref})
    install_static_methods(ta_base)
    install_species(ta_base)
  end

  defp install_static_methods(ctor) do
    from = {:builtin, "from", fn args, this -> TypedArray.static_from(args, this) end}
    of = {:builtin, "of", fn args, this -> TypedArray.static_of(args, this) end}

    Heap.put_ctor_static(from, "length", 1)
    Heap.put_ctor_prop_desc(from, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(from, "name", PropertyDescriptor.hidden_readonly())

    Heap.put_ctor_static(of, "length", 0)
    Heap.put_ctor_prop_desc(of, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(of, "name", PropertyDescriptor.hidden_readonly())

    Heap.put_ctor_static(ctor, "from", from)
    Heap.put_ctor_static(ctor, "of", of)
    Heap.put_ctor_prop_desc(ctor, "from", PropertyDescriptor.method())
    Heap.put_ctor_prop_desc(ctor, "of", PropertyDescriptor.method())
  end

  defp install_species(ctor) do
    getter = {:builtin, "get [Symbol.species]", fn _args, this -> this end}
    Heap.put_ctor_static(getter, "length", 0)
    Heap.put_ctor_prop_desc(getter, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(getter, "name", PropertyDescriptor.hidden_readonly())

    Heap.put_ctor_static(ctor, {:symbol, "Symbol.species"}, {:accessor, getter, nil})
    Heap.put_ctor_prop_desc(ctor, {:symbol, "Symbol.species"}, PropertyDescriptor.accessor())
  end

  defp mark_prototype_methods(ctor) do
    case Heap.get_class_proto(ctor) do
      {:obj, proto_ref} -> Heap.put_prop_desc(proto_ref, "at", PropertyDescriptor.method())
      _ -> :ok
    end
  end
end
