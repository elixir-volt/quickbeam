defmodule QuickBEAM.VM.ObjectModel.Get do
  @moduledoc """
  JavaScript property resolution: own properties, prototype chain, and getters.

  Spec:
  - ECMA-262 §7.3.2 Get
  - ECMA-262 §10.1.8 [[Get]]
  - ECMA-262 §10.1.8.1 OrdinaryGet
  - ECMA-262 §10.4 built-in exotic object internal methods where represented by VM values
  """

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Invocation

  alias QuickBEAM.VM.ObjectModel.{
    ArrayObjectGet,
    ExplicitOwnProperty,
    LengthGet,
    MapPropertyGet,
    OwnGet,
    PrimitiveWrapperGet,
    PrototypeGet,
    PrototypeTraversalGet,
    ProxyGet,
    SymbolGet
  }

  @doc "Reads a JavaScript property, including own lookup, prototype lookup, and getter invocation."
  def get(value, key) when is_binary(key), do: get(value, key, value)

  def get(value, key) when is_integer(key),
    do: get(value, Integer.to_string(key))

  def get(value, {:symbol, "Symbol.hasInstance"} = sym_key),
    do: get_callable_symbol(value, sym_key)

  def get(value, {:symbol, "Symbol.hasInstance", _} = sym_key),
    do: get_callable_symbol(value, SymbolGet.normalize(sym_key))

  def get(value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)

  def get(value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, SymbolGet.normalize(sym_key))

  def get(_, _), do: :undefined

  def get(value, key, receiver) when is_integer(key),
    do: get(value, Integer.to_string(key), receiver)

  def get({:obj, ref} = value, key, receiver) when is_binary(key) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => target, proxy_handler() => handler} = proxy ->
        ProxyGet.dispatch(proxy, target, handler, key, receiver, &ordinary_get/3, &target_slot/2)

      _ ->
        ordinary_get(value, key, receiver)
    end
  end

  def get(value, key, receiver) when is_binary(key), do: ordinary_get(value, key, receiver)

  defp ordinary_get(value, key, receiver) do
    case get_own_with_receiver(value, key, receiver) do
      :undefined ->
        if explicit_undefined_own?(value, key) do
          :undefined
        else
          result = get_prototype_raw(value, key)

          case result do
            {:accessor, getter, _} when getter != nil -> call_getter(getter, receiver)
            {:accessor, nil, _} -> :undefined
            _ -> result
          end
        end

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, receiver)

      {:accessor, nil, _} ->
        :undefined

      val ->
        val
    end
  end

  defp get_own_with_receiver({:obj, ref} = value, key, receiver) do
    case Heap.get_obj_raw(ref) do
      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, {:accessor, getter, _setter}} when getter != nil -> call_getter(getter, receiver)
          {:ok, {:accessor, nil, _setter}} -> :undefined
          _ -> get_own(value, key)
        end

      _ ->
        get_own(value, key)
    end
  end

  defp get_own_with_receiver(value, key, _receiver), do: get_own(value, key)

  defp get_callable_symbol(value, sym_key),
    do: SymbolGet.callable_property(value, sym_key, symbol_get_callbacks())

  defp get_symbol(value, sym_key),
    do: SymbolGet.property(value, sym_key, symbol_get_callbacks())

  defp symbol_get_callbacks do
    %{
      call_getter: &call_getter/2,
      explicit_own?: &explicit_undefined_own?/2,
      get_from_prototype: &get_from_prototype/2,
      get_own: &get_own/2
    }
  end

  @doc "Invokes a getter function with the provided receiver."
  def call_getter(fun, this_obj) do
    Invocation.invoke_with_receiver(fun, [], this_obj)
  end

  def regexp_flags(bytecode), do: LengthGet.regexp_flags(bytecode)

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
  def string_length(string), do: LengthGet.string_length(string)

  @doc "Returns the JavaScript `length` value for array-like, string, and function values."
  def length_of(obj), do: LengthGet.of(obj, length_callbacks())

  # ── Own property lookup ──

  defp wrapped_raw_proto_property(raw, key), do: PrimitiveWrapperGet.raw_proto_property(raw, key)

  defp string_proto_property(key), do: PrimitiveWrapperGet.string_proto_property(key)

  defp length_callbacks do
    %{
      get: &get/2,
      get_map_property: &get_map_property/3,
      shape_value: &shape_value/2
    }
  end

  defp shape_value({:accessor, getter, _setter}, receiver) when getter != nil,
    do: call_getter(getter, receiver)

  defp shape_value({:accessor, nil, _setter}, _receiver), do: :undefined
  defp shape_value(value, _receiver), do: value

  defp get_map_property(map, key, receiver),
    do: MapPropertyGet.property(map, key, receiver, &call_getter/2)

  defp get_own(value, key), do: OwnGet.property(value, key, own_get_callbacks())

  def own(value, key), do: get_own(value, key)

  defp own_get_callbacks do
    %{
      array_object: &array_object_callbacks/0,
      builtin_object: &builtin_object_callbacks/1,
      call_getter: &call_getter/2,
      object_map: &object_map_callbacks/1,
      proxy_get: &proxy_get/5,
      raw_object: &raw_object_callbacks/1,
      typed_array: &typed_array_callbacks/0
    }
  end

  defp proxy_get(proxy, target, handler, key, receiver),
    do: ProxyGet.dispatch(proxy, target, handler, key, receiver, &ordinary_get/3, &target_slot/2)

  defp typed_array_callbacks, do: %{get_map_property: &get_map_property/3}

  defp builtin_object_callbacks(receiver) do
    %{get_map_property: fn map, key -> get_map_property(map, key, receiver) end}
  end

  defp object_map_callbacks(ref) do
    %{
      array_prototype_length: fn -> LengthGet.array_prototype_length(ref) end,
      get_map_property: &get_map_property/3
    }
  end

  defp raw_object_callbacks(ref) do
    %{
      array_prototype_raw?: &LengthGet.array_prototype_raw?/1,
      array_prototype_length: fn -> LengthGet.array_prototype_length(ref) end,
      wrapped_raw_proto_property: &wrapped_raw_proto_property/2
    }
  end

  defp target_slot(target, key),
    do: ArrayObjectGet.target_slot(target, key, array_object_callbacks())

  defp array_object_callbacks do
    %{
      get_own: &get_own/2,
      get_from_prototype: &get_from_prototype/2
    }
  end

  # ── Prototype chain ──

  defp get_prototype_raw(value, key),
    do: PrototypeTraversalGet.raw_property(value, key, prototype_traversal_callbacks())

  defp explicit_undefined_own?(value, key), do: ExplicitOwnProperty.present?(value, key)

  defp get_from_prototype(value, key),
    do: PrototypeGet.property(value, key, prototype_get_callbacks())

  defp prototype_get_callbacks do
    %{
      call_getter: &call_getter/2,
      get_own: &get_own/2,
      prototype_property_with_receiver: &prototype_property_with_receiver/3,
      string_proto_property: &string_proto_property/1
    }
  end

  def prototype_property_with_receiver(target, key, receiver),
    do:
      PrototypeTraversalGet.property_with_receiver(
        target,
        key,
        receiver,
        prototype_traversal_callbacks()
      )

  defp prototype_traversal_callbacks do
    %{
      call_getter: &call_getter/2,
      get: &get/3,
      get_from_prototype: &get_from_prototype/2,
      get_own_value: &get/2
    }
  end
end
