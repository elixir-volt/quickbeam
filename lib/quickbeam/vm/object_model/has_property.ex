defmodule QuickBEAM.VM.ObjectModel.HasProperty do
  @moduledoc "Shared JavaScript [[HasProperty]]-style checks."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, OwnProperty, PropertyKey}
  alias QuickBEAM.VM.Runtime.TypedArray

  def has_property?(target, key), do: InternalMethods.has_property(target, key)

  def ordinary_has_property?({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} = map ->
        case TypedArray.integer_index_key(key) do
          {:ok, idx} ->
            not TypedArray.out_of_bounds?(obj) and idx < TypedArray.element_count(obj)

          :invalid ->
            false

          :not_integer_index ->
            OwnProperty.present?(obj, key) or prototype_has_property?(obj, map, key)
        end

      map when is_map(map) ->
        OwnProperty.present?(obj, key) or prototype_has_property?(obj, map, key)

      list when is_list(list) ->
        OwnProperty.present?(obj, key) or has_array_prototype_property?(ref, key)

      {:qb_arr, _} ->
        OwnProperty.present?(obj, key) or has_array_prototype_property?(ref, key)

      _ ->
        Get.get(obj, key) != :undefined
    end
  end

  def ordinary_has_property?(%QuickBEAM.VM.Function{} = fun, key),
    do: OwnProperty.present?(fun, key) or Get.get(fun, key) != :undefined

  def ordinary_has_property?({:closure, _, %QuickBEAM.VM.Function{}} = closure, key),
    do: OwnProperty.present?(closure, key) or Get.get(closure, key) != :undefined

  def ordinary_has_property?({:builtin, _, _} = builtin, key),
    do: OwnProperty.present?(builtin, key) or Get.get(builtin, key) != :undefined

  def ordinary_has_property?({:bound, _, _, _, _} = bound, key),
    do: OwnProperty.present?(bound, key) or Get.get(bound, key) != :undefined

  def ordinary_has_property?({:regexp, _, _, _} = regexp, key),
    do: Get.get(regexp, key) != :undefined

  def ordinary_has_property?({:regexp, _, _} = regexp, key),
    do: Get.get(regexp, key) != :undefined

  def ordinary_has_property?(map, key) when is_map(map), do: Map.has_key?(map, key)

  def ordinary_has_property?({:qb_arr, arr}, key) when is_integer(key),
    do: key >= 0 and key < :array.size(arr)

  def ordinary_has_property?({:qb_arr, arr}, key) when is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < :array.size(arr)
      :error -> false
    end
  end

  def ordinary_has_property?(list, key) when is_list(list) and is_integer(key),
    do: key >= 0 and key < length(list)

  def ordinary_has_property?(list, key) when is_list(list) and is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < length(list)
      :error -> false
    end
  end

  def ordinary_has_property?(_, _), do: false

  defp prototype_has_property?({:obj, ref}, map, key) do
    cond do
      Map.has_key?(map, :__internal_proto__) ->
        InternalMethods.has_property(Map.get(map, :__internal_proto__), key)

      Map.has_key?(map, proto()) ->
        InternalMethods.has_property(Map.get(map, proto()), key)

      object_prototype_ref?(ref) ->
        false

      true ->
        ordinary_has_property?(Heap.get_object_prototype(), key)
    end
  end

  defp object_prototype_ref?(ref) do
    case Heap.get_object_prototype() do
      {:obj, proto_ref} -> ref == proto_ref
      _ -> false
    end
  end

  defp has_array_prototype_property?(ref, key) do
    InternalMethods.has_property(Heap.get_array_proto(ref), key) or
      InternalMethods.has_property(Heap.get_object_prototype(), key)
  end
end
