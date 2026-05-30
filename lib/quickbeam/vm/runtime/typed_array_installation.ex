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
  alias QuickBEAM.VM.Runtime.TypedArray

  def install_builtin({:builtin, name, _} = ctor) do
    type = Map.fetch!(TypedArray.types(), name)
    typed_array_base = abstract_constructor()
    install_base_prototype(typed_array_base)
    base_proto = Heap.get_class_proto(typed_array_base)

    ConstructorRegistry.put_prototype(
      ctor,
      object extends: base_proto do
        prop("constructor", ctor)
      end
    )

    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
    Heap.put_ctor_static(ctor, "__proto__", typed_array_base)
    Heap.put_ctor_static(ctor, "BYTES_PER_ELEMENT", TypedArray.elem_size(type))
  end

  def constructor_prototype(name, ctor) do
    Runtime.global_class_proto(name) ||
      cached_prototype({:qb_typed_array_constructor_proto, name}, fn ->
        object extends: abstract_prototype() do
          prop("constructor", ctor)
        end
      end)
  end

  def abstract_constructor do
    {:builtin, "TypedArray", &__MODULE__.abstract_constructor_callback/2}
  end

  def abstract_constructor_callback(_args, _this) do
    JSThrow.type_error!("Abstract class TypedArray cannot be called")
  end

  def abstract_prototype do
    cached_prototype(:qb_typed_array_abstract_proto, fn ->
      TypedArray.base_prototype_properties()
      |> Map.merge(
        object heap: false, extends: Heap.get_object_prototype() do
          prop("constructor", abstract_constructor())
          prop("toString", Get.get(Heap.get_array_proto(), "toString"))
        end
      )
      |> Heap.wrap()
    end)
  end

  defp install_base_prototype(typed_array_base) do
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

        Installer.install_prototype_specs(typed_array_base_ref, TypedArray)
        Heap.put_prop_desc(typed_array_base_ref, "constructor", PropertyDescriptor.constructor())

        ConstructorRegistry.put_prototype(typed_array_base, {:obj, typed_array_base_ref})
        Heap.put_ctor_prop_desc(typed_array_base, "prototype", PropertyDescriptor.prototype())
        Installer.install_static_specs(typed_array_base, TypedArray)
    end
  end

  defp cached_prototype(key, build), do: PrototypeState.cached_any(key, build)
end
