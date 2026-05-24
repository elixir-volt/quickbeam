defmodule QuickBEAM.VM.ObjectModel.OwnGet do
  @moduledoc "Own-property dispatch for ObjectModel.Get."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap

  alias QuickBEAM.VM.ObjectModel.{
    ArrayObjectGet,
    BuiltinObjectGet,
    CallableOwnGet,
    IndexedExoticGet,
    ObjectMapGet,
    RawObjectGet,
    RegExpStateGet,
    SymbolExoticGet,
    TypedArrayObjectGet
  }

  def property({:obj, ref}, key, callbacks) do
    case Heap.get_obj_raw(ref) do
      nil ->
        :undefined

      %{proxy_target() => target, proxy_handler() => handler} = proxy ->
        proxy_property(proxy, target, handler, key, ref, callbacks)

      {:qb_arr, _} = arr ->
        array_property(ref, arr, key, callbacks)

      list when is_list(list) ->
        array_property(ref, list, key, callbacks)

      raw when is_tuple(raw) ->
        RawObjectGet.own_property(raw, key, callbacks.raw_object.(ref))

      %{date_ms() => _} = map ->
        BuiltinObjectGet.date_property(map, key, callbacks.builtin_object.({:obj, ref}))

      %{typed_array() => true} = map ->
        TypedArrayObjectGet.own_property({:obj, ref}, map, key, callbacks.typed_array.())

      %{buffer() => _} = map ->
        BuiltinObjectGet.buffer_property(map, key)

      map when is_map(map) ->
        ObjectMapGet.own_property(ref, map, key, callbacks.object_map.(ref))
    end
  end

  def property({:qb_arr, _} = array, key, _callbacks),
    do: IndexedExoticGet.own_property(array, key)

  def property(list, key, _callbacks) when is_list(list),
    do: IndexedExoticGet.own_property(list, key)

  def property(string, key, _callbacks) when is_binary(string),
    do: IndexedExoticGet.own_property(string, key)

  def property(number, _key, _callbacks) when is_number(number), do: :undefined
  def property(true, _key, _callbacks), do: :undefined
  def property(false, _key, _callbacks), do: :undefined
  def property(nil, _key, _callbacks), do: :undefined
  def property(:undefined, _key, _callbacks), do: :undefined

  def property({:builtin, _, _} = callable, key, callbacks),
    do: CallableOwnGet.own_property(callable, key, callbacks.call_getter)

  def property(%QuickBEAM.VM.Function{} = callable, key, callbacks),
    do: CallableOwnGet.own_property(callable, key, callbacks.call_getter)

  def property({:closure, _, %QuickBEAM.VM.Function{}} = callable, key, callbacks),
    do: CallableOwnGet.own_property(callable, key, callbacks.call_getter)

  def property({:bound, _, _, _, _} = callable, key, callbacks),
    do: CallableOwnGet.own_property(callable, key, callbacks.call_getter)

  def property({:regexp, _, _, _} = regexp, key, callbacks),
    do: RegExpStateGet.own_property(regexp, key, callbacks.call_getter)

  def property({:regexp, _, _} = regexp, key, callbacks),
    do: RegExpStateGet.own_property(regexp, key, callbacks.call_getter)

  def property({:symbol, _} = symbol, key, _callbacks),
    do: SymbolExoticGet.own_property(symbol, key)

  def property({:symbol, _, _} = symbol, key, _callbacks),
    do: SymbolExoticGet.own_property(symbol, key)

  def property(_, _, _), do: :undefined

  defp proxy_property(proxy, target, handler, key, ref, callbacks),
    do: callbacks.proxy_get.(proxy, target, handler, key, {:obj, ref})

  defp array_property(ref, data, key, callbacks) do
    case Heap.get_regexp_result(ref) do
      %{^key => value} -> value
      _ -> ArrayObjectGet.own_property(ref, data, key, callbacks.array_object.())
    end
  end
end
