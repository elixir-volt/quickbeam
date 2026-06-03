defmodule QuickBEAM.VM.Runtime.TypedArrayInstallation do
  @moduledoc "Installation and prototype helpers for the TypedArray intrinsic family."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Installer
  alias QuickBEAM.VM.Execution.PrototypeState
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.ConstructorRegistry
  alias QuickBEAM.VM.Runtime.TypedArray.Metadata

  def install_builtin(ctor, spec_module) do
    {:builtin, name, _} = ctor
    type = Map.fetch!(Metadata.types(), name)
    typed_array_base = abstract_constructor()
    install_base_prototype(typed_array_base, spec_module)
    base_proto = Heap.get_class_proto(typed_array_base)

    {:obj, proto_ref} =
      proto =
      object extends: base_proto do
        prop("constructor", ctor)
        prop("BYTES_PER_ELEMENT", Metadata.elem_size(type))
      end

    Heap.put_prop_desc(proto_ref, "BYTES_PER_ELEMENT", bytes_per_element_descriptor())
    ConstructorRegistry.put_prototype(ctor, proto)

    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
    Heap.put_ctor_static(ctor, "__proto__", typed_array_base)
    Heap.put_ctor_static(ctor, "BYTES_PER_ELEMENT", Metadata.elem_size(type))
    Heap.put_ctor_prop_desc(ctor, "BYTES_PER_ELEMENT", bytes_per_element_descriptor())
  end

  def constructor_prototype(name, ctor, spec_module) do
    Runtime.global_class_proto(name) ||
      cached_prototype({:qb_typed_array_constructor_proto, name}, fn ->
        type = Map.fetch!(Metadata.types(), name)

        {:obj, ref} =
          proto =
          object extends: abstract_prototype(spec_module) do
            prop("constructor", ctor)
            prop("BYTES_PER_ELEMENT", Metadata.elem_size(type))
          end

        Heap.put_prop_desc(ref, "BYTES_PER_ELEMENT", bytes_per_element_descriptor())
        proto
      end)
  end

  def abstract_constructor do
    {:builtin, "TypedArray", &__MODULE__.abstract_constructor_callback/2}
  end

  def abstract_constructor_callback(_args, _this) do
    JSThrow.type_error!("Abstract class TypedArray cannot be called")
  end

  def abstract_prototype(spec_module) do
    cached_prototype(:qb_typed_array_abstract_proto, fn ->
      spec_module.base_prototype_properties()
      |> Map.merge(
        object heap: false, extends: Heap.get_object_prototype() do
          prop("constructor", abstract_constructor())
          prop("toString", Get.get(Heap.get_array_proto(), "toString"))
        end
      )
      |> Heap.wrap()
    end)
  end

  defp install_base_prototype(typed_array_base, spec_module) do
    case Heap.get_class_proto(typed_array_base) do
      {:obj, _} ->
        :ok

      _ ->
        typed_array_base_ref = make_ref()

        Heap.put_obj(
          typed_array_base_ref,
          object heap: false, extends: Heap.get_object_prototype() do
            prop("constructor", typed_array_base)
          end
        )

        Installer.install_prototype_specs(typed_array_base_ref, spec_module)
        alias_base_prototype_methods(typed_array_base_ref)
        Heap.put_prop_desc(typed_array_base_ref, "constructor", PropertyDescriptor.constructor())

        ConstructorRegistry.put_prototype(typed_array_base, {:obj, typed_array_base_ref})
        Heap.put_ctor_prop_desc(typed_array_base, "prototype", PropertyDescriptor.prototype())
        Installer.install_static_specs(typed_array_base, spec_module)
    end
  end

  defp alias_base_prototype_methods(ref) do
    case Heap.get_obj(ref, %{}) do
      %{"values" => values} = map ->
        aliased =
          map
          |> Map.put({:symbol, "Symbol.iterator"}, values)
          |> Map.put("toString", Get.get(Heap.get_array_proto(), "toString"))

        Heap.put_obj(ref, aliased)

      _ ->
        :ok
    end
  end

  defp bytes_per_element_descriptor do
    PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
  end

  defp cached_prototype(key, build), do: PrototypeState.cached_any(key, build)
end
