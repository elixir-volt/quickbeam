defmodule QuickBEAM.VM.ObjectModel.InternalMethods do
  @moduledoc "Dispatch facade for ECMAScript object internal methods."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0, typed_array: 0]

  alias QuickBEAM.VM.Heap

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Delete,
    Get,
    HasProperty,
    OwnProperty,
    ProxyDelete,
    ProxyExtensible,
    ProxyHas,
    ProxyOwnKeys,
    ProxyPrototype,
    ProxySet,
    Put,
    Prototype
  }

  def kind({:obj, ref}) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => _target} -> :proxy
      %{typed_array() => true} -> :typed_array
      list when is_list(list) -> :array
      _ -> :ordinary
    end
  end

  def kind(%QuickBEAM.VM.Function{}), do: :function
  def kind({:closure, _, %QuickBEAM.VM.Function{}}), do: :function
  def kind({:builtin, _, _}), do: :function
  def kind({:bound, _, _, _, _}), do: :function
  def kind(_), do: :primitive

  def get(obj, key, receiver \\ nil), do: get_by_kind(kind(obj), obj, key, receiver || obj)
  def set(obj, key, value, receiver \\ nil)

  def set(obj, key, value, receiver),
    do: set_by_kind(kind(obj), obj, key, value, receiver || obj)

  def has_property(obj, key), do: has_property_by_kind(kind(obj), obj, key)

  def own_property(obj, key), do: own_property_by_kind(kind(obj), obj, key)

  def define_own_property(obj, key, descriptor),
    do: define_own_property(obj, key, descriptor, descriptor)

  def define_own_property(obj, key, desc_obj, raw_desc),
    do: define_own_property_by_kind(kind(obj), obj, key, desc_obj, raw_desc)

  def delete(obj, key), do: delete_by_kind(kind(obj), obj, key)

  def own_keys(obj), do: own_keys_by_kind(kind(obj), obj)

  def extensible?(obj), do: extensible_by_kind(kind(obj), obj)

  def get_prototype_of(obj), do: get_prototype_of_by_kind(kind(obj), obj)

  def set_prototype_of(obj, proto), do: set_prototype_of_by_kind(kind(obj), obj, proto)

  defp get_by_kind(_kind, obj, key, receiver), do: Get.get(obj, key, receiver)

  defp set_by_kind(:proxy, obj, key, value, receiver),
    do: ProxySet.dispatch(obj, key, value, receiver, &Put.ordinary_set/4)

  defp set_by_kind(_kind, obj, key, value, receiver),
    do: Put.ordinary_set(obj, key, value, receiver)

  defp has_property_by_kind(:proxy, obj, key),
    do: ProxyHas.dispatch(obj, key, &HasProperty.ordinary_has_property?/2)

  defp has_property_by_kind(_kind, obj, key), do: HasProperty.ordinary_has_property?(obj, key)

  defp own_property_by_kind(_kind, obj, key), do: OwnProperty.descriptor(obj, key)

  defp define_own_property_by_kind(_kind, obj, key, desc_obj, raw_desc),
    do: Define.property(obj, key, desc_obj, raw_desc)

  defp delete_by_kind(:proxy, obj, key),
    do: ProxyDelete.dispatch(obj, key, &Delete.ordinary_delete_property/2)

  defp delete_by_kind(_kind, obj, key), do: Delete.ordinary_delete_property(obj, key)

  defp own_keys_by_kind(:proxy, obj),
    do: ProxyOwnKeys.dispatch(obj, &OwnProperty.ordinary_own_keys/1)

  defp own_keys_by_kind(_kind, obj), do: OwnProperty.ordinary_own_keys(obj)

  defp extensible_by_kind(:proxy, obj), do: ProxyExtensible.dispatch(obj, &ordinary_extensible?/1)
  defp extensible_by_kind(_kind, obj), do: ordinary_extensible?(obj)

  defp get_prototype_of_by_kind(:proxy, {:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy -> ProxyPrototype.get(proxy, &Prototype.get/1)
      _ -> Prototype.get({:obj, ref})
    end
  end

  defp get_prototype_of_by_kind(_kind, obj), do: Prototype.get(obj)

  defp set_prototype_of_by_kind(:proxy, {:obj, ref}, proto) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy ->
        ProxyPrototype.set(proxy, proto, &ordinary_set_prototype_of/2)

      _ ->
        ordinary_set_prototype_of({:obj, ref}, proto)
    end
  end

  defp set_prototype_of_by_kind(_kind, obj, proto), do: ordinary_set_prototype_of(obj, proto)

  defp ordinary_set_prototype_of(obj, proto) do
    Prototype.set(obj, proto)
    true
  end

  defp ordinary_extensible?({:obj, ref}), do: Heap.extensible?(ref)
  defp ordinary_extensible?(obj), do: Heap.extensible?(obj)
end
