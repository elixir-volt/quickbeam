defmodule QuickBEAM.VM.ObjectModel.PrototypeGet do
  @moduledoc "Prototype fallback lookup for ObjectModel.Get."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0, proxy_target: 0]

  alias QuickBEAM.VM.{Builtin, Heap, Runtime}

  alias QuickBEAM.VM.ObjectModel.{
    ArrayExoticGet,
    BuiltinExoticGet,
    FunctionPrototypeGet,
    PrimitiveExoticGet,
    PrototypeLookup
  }

  alias QuickBEAM.VM.Runtime.{BigInt, Boolean, Function, Number}

  def property({:obj, ref}, key, callbacks) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} -> array_or_arguments_property(ref, {:obj, ref}, key)
      list when is_list(list) -> array_or_arguments_property(ref, {:obj, ref}, key)
      map when is_map(map) -> map_property(map, {:obj, ref}, key, callbacks)
      _ -> :undefined
    end
  end

  def property({:qb_arr, _}, "constructor", _callbacks),
    do: Map.get(Runtime.global_bindings(), "Array", :undefined)

  def property({:qb_arr, _}, key, _callbacks), do: array_proto_property(key)

  def property(list, "constructor", _callbacks) when is_list(list),
    do: Map.get(Runtime.global_bindings(), "Array", :undefined)

  def property(list, key, _callbacks) when is_list(list), do: array_proto_property(key)

  def property(string, key, callbacks) when is_binary(string),
    do: primitive_or_class_proto(callbacks.string_proto_property.(key), key, "String", string)

  def property(number, key, _callbacks) when is_number(number),
    do: primitive_or_class_proto(Number.proto_property(key), key, "Number", number)

  def property(number, key, _callbacks) when number in [:nan, :infinity, :neg_infinity],
    do: primitive_or_class_proto(Number.proto_property(key), key, "Number", number)

  def property(true, key, _callbacks),
    do: primitive_or_class_proto(Boolean.proto_property(key), key, "Boolean", true)

  def property(false, key, _callbacks),
    do: primitive_or_class_proto(Boolean.proto_property(key), key, "Boolean", false)

  def property({:symbol, _, _} = receiver, key, _callbacks),
    do: primitive_or_class_proto(:undefined, key, "Symbol", receiver)

  def property({:symbol, _} = receiver, key, _callbacks),
    do: primitive_or_class_proto(:undefined, key, "Symbol", receiver)

  def property({:bigint, _} = receiver, key, _callbacks),
    do: primitive_or_class_proto(BigInt.proto_property(key), key, "BigInt", receiver)

  def property(%QuickBEAM.VM.Function{} = fun, "constructor", _callbacks),
    do: FunctionPrototypeGet.constructor(fun)

  def property(%QuickBEAM.VM.Function{} = fun, {:symbol, "Symbol.toStringTag"} = key, _callbacks),
    do: FunctionPrototypeGet.to_string_tag(fun, key)

  def property(%QuickBEAM.VM.Function{} = fun, key, _callbacks),
    do: FunctionPrototypeGet.own_or_parent(fun, key)

  def property({:closure, _, %QuickBEAM.VM.Function{} = fun}, "constructor", _callbacks),
    do: FunctionPrototypeGet.constructor(fun)

  def property(
        {:closure, _, %QuickBEAM.VM.Function{}} = closure,
        {:symbol, "Symbol.toStringTag"} = key,
        _callbacks
      ),
      do: FunctionPrototypeGet.to_string_tag(closure, key)

  def property({:closure, _, %QuickBEAM.VM.Function{}} = closure, key, callbacks),
    do: FunctionPrototypeGet.closure_own_or_parent(closure, key, callbacks.call_getter)

  def property({:bound, _, _, _, _} = bound, key, _callbacks),
    do: FunctionPrototypeGet.fallback(Function.proto_property(bound, key), bound, key)

  def property({:builtin, "Error", _}, _key, _callbacks), do: :undefined

  def property({:builtin, name, callback} = fun, key, _callbacks)
      when is_binary(name) and is_function(callback),
      do: FunctionPrototypeGet.fallback(:undefined, fun, key)

  def property({:builtin, name, props}, key, callbacks) when is_binary(name) and is_map(props),
    do: callbacks.get_own.(Heap.get_object_prototype(), key)

  def property(_, _, _), do: :undefined

  defp array_or_arguments_property(ref, obj, key) do
    if Heap.get_array_prop(ref, "__arguments__") == true do
      arguments_proto_property(obj, key)
    else
      array_proto_property(obj, key)
    end
  end

  defp map_property(map, obj, key, callbacks) do
    cond do
      Map.has_key?(map, proxy_target()) and Builtin.callable?(Map.get(map, proxy_target())) ->
        FunctionPrototypeGet.fallback(:undefined, Map.get(map, proxy_target()), key)

      Map.get(map, "__array_buffer_kind__") == :shared_array_buffer and
          Map.has_key?(map, :__internal_proto__) ->
        callbacks.prototype_property_with_receiver.(Map.get(map, :__internal_proto__), key, obj)

      (builtin = BuiltinExoticGet.map_proto_property(map, key)) != :undefined ->
        builtin

      Map.has_key?(map, :__internal_proto__) ->
        callbacks.prototype_property_with_receiver.(Map.get(map, :__internal_proto__), key, obj)

      Map.get(map, proto()) == :null_proto ->
        :undefined

      Map.has_key?(map, proto()) ->
        callbacks.prototype_property_with_receiver.(Map.get(map, proto()), key, obj)

      true ->
        PrototypeLookup.object_prototype_property(obj, key)
    end
  end

  defp primitive_or_class_proto(default_value, key, class_name, receiver),
    do: PrimitiveExoticGet.prototype_property(default_value, key, class_name, receiver)

  defp arguments_proto_property(obj, {:symbol, "Symbol.iterator"}) do
    case array_proto_property(obj, {:symbol, "Symbol.iterator"}) do
      :undefined -> PrototypeLookup.object_prototype_property(obj, {:symbol, "Symbol.iterator"})
      value -> value
    end
  end

  defp arguments_proto_property(obj, key), do: PrototypeLookup.object_prototype_property(obj, key)

  defp array_proto_property({:obj, _} = obj, key), do: ArrayExoticGet.proto_property(obj, key)
  defp array_proto_property(key), do: ArrayExoticGet.proto_property(key)
end
