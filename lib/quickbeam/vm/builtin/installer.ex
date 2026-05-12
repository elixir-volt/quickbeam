defmodule QuickBEAM.VM.Builtin.Installer do
  @moduledoc "Installs declarative builtin definitions into the VM global heap."

  alias QuickBEAM.VM.Builtin.Definition
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Constructors

  @doc "Installs all builtin definitions and returns a global binding map."
  def install_all(definitions) do
    definitions
    |> Enum.filter(& &1.auto_install?)
    |> Enum.reduce(%{}, fn definition, bindings ->
      Map.put(bindings, definition.name, install(definition))
    end)
  end

  @doc "Installs a single builtin definition and returns its constructor."
  def install(%Definition{} = definition) do
    ctor = Constructors.register(definition.name, definition.constructor, auto_proto: true)

    install_constructor_length(ctor, definition)
    Heap.put_ctor_prop_desc(ctor, "prototype", definition.prototype_descriptor)
    install_prototype(ctor, definition)

    ctor
  end

  defp install_constructor_length(_ctor, %Definition{length: nil}), do: :ok

  defp install_constructor_length(ctor, %Definition{length: length}) do
    Heap.put_ctor_static(ctor, "length", length)

    Heap.put_ctor_prop_desc(ctor, "length", %{
      writable: false,
      enumerable: false,
      configurable: true
    })
  end

  defp install_prototype(ctor, definition) do
    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} ->
        install_prototype_parent(proto_ref, definition.prototype_parent)
        Heap.put_prop_desc(proto_ref, "constructor", definition.constructor_descriptor)

        Enum.each(definition.prototype_properties, fn property ->
          Heap.put_obj_key(proto_ref, property.key, property.value)
          Heap.put_prop_desc(proto_ref, property.key, property.descriptor)
        end)

      _ ->
        :ok
    end
  end

  defp install_prototype_parent(proto_ref, :object),
    do: Heap.put_obj_key(proto_ref, "__proto__", Heap.get_object_prototype())

  defp install_prototype_parent(_proto_ref, nil), do: :ok
end
