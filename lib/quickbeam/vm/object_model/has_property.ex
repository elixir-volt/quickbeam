defmodule QuickBEAM.VM.ObjectModel.HasProperty do
  @moduledoc "Shared JavaScript [[HasProperty]]-style checks."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Get, OwnProperty}

  def has_property?({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        has_trap = Get.get(handler, "has")

        if has_trap != :undefined do
          Values.truthy?(Invocation.invoke_callback_or_throw(has_trap, [target, key]))
        else
          has_property?(target, key)
        end

      map when is_map(map) ->
        OwnProperty.present?(obj, key) or has_property?(Map.get(map, proto()), key)

      list when is_list(list) ->
        OwnProperty.present?(obj, key)

      {:qb_arr, _} ->
        OwnProperty.present?(obj, key) or has_array_prototype_property?(ref, key)

      _ ->
        Get.get(obj, key) != :undefined
    end
  end

  def has_property?(%QuickBEAM.VM.Function{} = fun, key), do: Get.get(fun, key) != :undefined

  def has_property?({:closure, _, %QuickBEAM.VM.Function{}} = closure, key),
    do: Get.get(closure, key) != :undefined

  def has_property?({:builtin, _, _} = builtin, key), do: Get.get(builtin, key) != :undefined
  def has_property?({:bound, _, _, _, _} = bound, key), do: Get.get(bound, key) != :undefined
  def has_property?(map, key) when is_map(map), do: Map.has_key?(map, key)

  def has_property?({:qb_arr, arr}, key) when is_integer(key),
    do: key >= 0 and key < :array.size(arr)

  def has_property?(list, key) when is_list(list) and is_integer(key),
    do: key >= 0 and key < length(list)

  def has_property?(_, _), do: false

  defp has_array_prototype_property?(ref, key) do
    has_property?(Heap.get_array_proto(ref), key) or
      has_property?(Heap.get_object_prototype(), key)
  end
end
