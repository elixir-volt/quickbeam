defmodule QuickBEAM.VM.ObjectModel.Copy do
  @moduledoc "Object spread and property copying: `append_spread`, `copy_data_properties`, and array/iterator flattening."

  import QuickBEAM.VM.Heap.Keys,
    only: [
      internal?: 1,
      internal_namespace?: 1,
      key_order: 0,
      proto: 0,
      proxy_handler: 0,
      proxy_target: 0
    ]

  import QuickBEAM.VM.Value, only: [is_symbol: 1, is_nullish: 1]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.Execution.RegexpState

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Get,
    InternalMethods,
    OwnProperty,
    PropertyKey,
    Semantics,
    WrappedPrimitive
  }

  @doc "Appends values from a spread source into an array-like target and returns the next index."
  def append_spread(arr, idx, obj) do
    src_list = spread_source_to_list(obj)
    arr_list = spread_target_to_list(arr)
    new_idx = if(is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)
    merged = arr_list ++ src_list

    merged_obj =
      case arr do
        {:obj, ref} ->
          Heap.put_obj(ref, merged)
          {:obj, ref}

        _ ->
          merged
      end

    {new_idx, merged_obj}
  end

  @doc "Copies enumerable own string and symbol properties from a source object to a target object."
  def copy_data_properties(target, source, exclude \\ nil)

  def copy_data_properties({:obj, _}, source, exclude) when is_nullish(source) do
    excluded_keys(exclude)
    :ok
  end

  def copy_data_properties({:obj, _} = target, source, exclude) do
    {source, exclude} = normalize_computed_rest_operands(source, exclude)
    excluded = excluded_keys(exclude)

    source
    |> copy_source_keys()
    |> Enum.each(fn key -> copy_data_property(target, source, key, excluded) end)

    :ok
  end

  def copy_data_properties(_target, _source, _exclude), do: :ok

  defp normalize_computed_rest_operands(source_key, {:obj, _} = source)
       when is_binary(source_key) or is_symbol(source_key) do
    exclusions = object_rest_transient_exclusions(source)

    exclusions =
      if exclusions == [] and is_symbol(source_key),
        do: following_string_keys(source, source_key),
        else: exclusions

    if exclusions == [] do
      {source_key, source}
    else
      {source, Heap.wrap([source_key | exclusions])}
    end
  end

  defp normalize_computed_rest_operands(source, exclude), do: {source, exclude}

  defp transient_exclusion_key?(key),
    do: key in [key_order(), proto(), proxy_target(), proxy_handler(), :__internal_proto__]

  defp following_string_keys(source, source_key) do
    source
    |> InternalMethods.own_keys()
    |> Enum.drop_while(&(&1 != source_key))
    |> case do
      [_source_key | rest] -> Enum.take_while(rest, &is_binary/1)
      _ -> []
    end
  end

  defp object_rest_transient_exclusions({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        map
        |> Map.reject(fn {key, value} -> transient_exclusion_key?(key) or value != nil end)
        |> Map.keys()

      _ ->
        []
    end
  end

  defp copy_source_keys({:obj, _} = source), do: InternalMethods.own_keys(source)

  defp copy_source_keys(source) when is_binary(source) do
    source
    |> Get.string_length()
    |> numeric_index_keys()
  end

  defp copy_source_keys(source) when is_map(source), do: enumerable_copy_keys(source)

  defp copy_source_keys(_source), do: []

  defp copy_data_property(target, source, key, excluded) do
    prop_key = PropertyKey.normalize(key)

    if property_key?(prop_key) and prop_key not in excluded do
      descriptor = own_descriptor(source, prop_key)

      if descriptor != :undefined and Runtime.truthy?(Get.get(descriptor, "enumerable")) do
        Define.create_data_property_or_throw(target, prop_key, Get.get(source, prop_key))
      end
    end
  end

  defp own_descriptor({:obj, _} = source, key), do: OwnProperty.descriptor(source, key)

  defp own_descriptor(source, key) when is_binary(source) do
    if key in numeric_index_keys(Get.string_length(source)) do
      QuickBEAM.VM.ObjectModel.PropertyDescriptor.data_object(
        Get.get(source, key),
        QuickBEAM.VM.ObjectModel.PropertyDescriptor.attrs(
          writable: false,
          enumerable: true,
          configurable: false
        )
      )
    else
      :undefined
    end
  end

  defp own_descriptor(source, key) when is_map(source) do
    if Map.has_key?(source, key) do
      QuickBEAM.VM.ObjectModel.PropertyDescriptor.data_object(
        Map.get(source, key),
        QuickBEAM.VM.ObjectModel.PropertyDescriptor.attrs(
          writable: true,
          enumerable: true,
          configurable: true
        )
      )
    else
      :undefined
    end
  end

  defp own_descriptor(_source, _key), do: :undefined

  defp excluded_keys(nil), do: []

  defp excluded_keys({:obj, eref}) do
    case Heap.get_obj(eref) do
      {:qb_arr, arr} -> :array.to_list(arr) |> Enum.map(&property_key/1)
      list when is_list(list) -> Enum.map(list, &property_key/1)
      map when is_map(map) -> enumerable_copy_keys(map) |> Enum.map(&property_key/1)
      _ -> []
    end
  end

  defp excluded_keys(_), do: []

  @doc "Returns enumerable own string and symbol properties as a map of property names to values."
  def enumerable_string_props({:obj, ref} = source_obj) do
    case Heap.get_obj_raw(ref) do
      {:qb_arr, arr} ->
        arr
        |> :array.sparse_to_orddict()
        |> Enum.reduce(%{}, fn {i, _value}, acc ->
          Map.put(acc, Integer.to_string(i), Get.get(source_obj, Integer.to_string(i)))
        end)

      raw when is_tuple(raw) ->
        if Heap.shape?(raw) do
          raw
          |> shape_enumerable_map()
          |> resolve_accessors(source_obj)
        else
          %{}
        end

      list when is_list(list) ->
        Enum.reduce(0..max(length(list) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Get.get(source_obj, Integer.to_string(i)))
        end)

      %{proxy_target() => _target, proxy_handler() => _handler} = proxy_map ->
        proxy_enumerable_string_props(source_obj, proxy_map)

      map when is_map(map) ->
        map
        |> Map.keys()
        |> Enum.filter(&enumerable_key_candidate?/1)
        |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)
        |> Enum.reduce(%{}, fn key, acc -> Map.put(acc, key, Get.get(source_obj, key)) end)

      _ ->
        %{}
    end
  end

  def enumerable_string_props(map) when is_map(map), do: map
  def enumerable_string_props(_), do: %{}

  defp proxy_enumerable_string_props(source_obj, _proxy_map) do
    source_obj
    |> InternalMethods.own_keys()
    |> Enum.reduce(%{}, fn key, acc ->
      descriptor = InternalMethods.own_property(source_obj, key)

      if property_key?(key) and descriptor != :undefined and
           Get.get(descriptor, "enumerable") == true do
        Map.put(acc, key, Get.get(source_obj, key))
      else
        acc
      end
    end)
  end

  defp shape_enumerable_map(raw) do
    raw
    |> Heap.shape_to_map()
    |> Map.delete(key_order())
  end

  defp resolve_accessors(map, obj) do
    Map.new(map, fn
      {k, {:accessor, getter, _}} when getter != nil -> {k, Get.call_getter(getter, obj)}
      pair -> pair
    end)
  end

  @doc "Returns enumerable property keys in JavaScript enumeration order."
  def enumerable_keys({:obj, ref} = obj) do
    case Heap.get_obj_raw(ref) do
      raw when is_tuple(raw) ->
        if Heap.shape?(raw) do
          own_keys =
            shape_virtual_string_keys(raw) ++
              (Heap.shape_keys(raw)
               |> Enum.filter(&enumerable_key_candidate?/1)
               |> Enum.reject(fn key ->
                 match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
               end))

          proto_keys = enumerable_proto_keys(Heap.shape_proto(raw))
          Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))
        else
          enumerable_keys_from_raw(obj, ref, raw)
        end

      raw ->
        enumerable_keys_from_raw(obj, ref, raw)
    end
  end

  def enumerable_keys(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(fn key -> internal?(key) end)
    |> Runtime.sort_numeric_keys()
  end

  def enumerable_keys(list) when is_list(list), do: numeric_index_keys(length(list))

  def enumerable_keys(string) when is_binary(string),
    do: numeric_index_keys(Get.string_length(string))

  def enumerable_keys(%QuickBEAM.VM.Function{} = fun), do: enumerable_callable_keys(fun)

  def enumerable_keys({:closure, _, %QuickBEAM.VM.Function{}} = fun),
    do: enumerable_callable_keys(fun)

  def enumerable_keys({:builtin, _, _} = fun), do: enumerable_callable_keys(fun)
  def enumerable_keys({:bound, _, _, _, _} = fun), do: enumerable_callable_keys(fun)
  def enumerable_keys({:regexp, _, _, ref}), do: enumerable_regexp_keys(ref)
  def enumerable_keys({:regexp, _, _}), do: enumerable_regexp_keys(nil)

  def enumerable_keys(_), do: []

  defp enumerable_keys_from_raw(obj, ref, raw) do
    case raw || %{} do
      %{proxy_target() => _target, proxy_handler() => _handler} ->
        obj
        |> InternalMethods.own_keys()
        |> Enum.filter(&(is_binary(&1) and InternalMethods.enumerable_own_property?(obj, &1)))

      {:qb_arr, arr} ->
        Semantics.enumerable_array_keys(ref, arr, array_prop_keys(ref))

      list when is_list(list) ->
        numeric_index_keys(length(list))

      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        all_own = Map.keys(map) |> Enum.filter(&is_binary/1)
        proto_keys = enumerable_proto_keys(Map.get(map, proto()))
        Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in all_own)))

      _ ->
        []
    end
  end

  @doc "Converts a spread source value into the list of values to append."
  def spread_source_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_source_to_list(list) when is_list(list), do: list
  def spread_source_to_list(string) when is_binary(string), do: String.codepoints(string)

  def spread_source_to_list({:obj, _} = obj) do
    QuickBEAM.VM.Semantics.Iterators.iterable_to_list(obj)
  end

  def spread_source_to_list(value), do: QuickBEAM.VM.Semantics.Iterators.iterable_to_list(value)

  @doc "Converts a spread target value into its current list representation."
  def spread_target_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_target_to_list(list) when is_list(list), do: list
  def spread_target_to_list({:obj, _} = obj), do: Heap.to_list(obj)
  def spread_target_to_list(_), do: []

  defp array_prop_keys(ref) do
    ref
    |> Heap.get_array_props()
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_binary(key) and not internal_namespace?(key) and
        not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
    end)
  end

  defp enumerable_object_keys(map, ref) do
    raw_keys =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> []
      end

    raw_keys = wrapped_string_keys(map) ++ raw_keys ++ (Map.keys(map) -- raw_keys)

    raw_keys
    |> Enum.filter(&enumerable_key_candidate?/1)
    |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)
  end

  defp wrapped_string_keys(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, string} when is_binary(string) -> numeric_index_keys(Get.string_length(string))
      _ -> []
    end
  end

  defp shape_virtual_string_keys(raw) do
    case Heap.raw_fetch(raw, WrappedPrimitive.slot(:string)) do
      {:ok, string} when is_binary(string) -> numeric_index_keys(Get.string_length(string))
      _ -> []
    end
  end

  defp enumerable_regexp_keys(ref) do
    own_keys =
      case ref do
        nil ->
          []

        _ ->
          ref
          |> RegexpState.get()
          |> Map.keys()
          |> Enum.filter(fn key ->
            is_binary(key) and key not in ["flags", "source", "lastIndex"] and
              not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
          end)
      end

    proto_keys =
      case Runtime.global_class_proto("RegExp") do
        {:obj, _} = proto -> enumerable_keys(proto)
        _ -> []
      end

    Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))
  end

  defp enumerable_callable_keys(fun) do
    own_keys =
      fun
      |> Heap.get_ctor_statics()
      |> Map.keys()
      |> Enum.filter(fn key ->
        is_binary(key) and not match?(%{enumerable: false}, Heap.get_prop_desc(fun, key))
      end)

    proto_keys =
      case Heap.get_func_proto() do
        {:obj, _} = proto -> enumerable_keys(proto)
        _ -> []
      end

    Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))
  end

  defp enumerable_proto_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        parent_keys = enumerable_proto_keys(Map.get(map, proto()))
        own_keys ++ Enum.reject(parent_keys, &(&1 in own_keys))

      _ ->
        []
    end
  end

  defp enumerable_proto_keys(_), do: []

  defp enumerable_key_candidate?(key) when is_binary(key),
    do: not internal?(key)

  defp enumerable_key_candidate?(key), do: QuickBEAM.VM.Value.symbol?(key)

  defp property_key?(key), do: PropertyKey.property_key?(key)

  defp property_key(key), do: PropertyKey.normalize(key)

  defp enumerable_copy_keys(map) do
    string_keys =
      map
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(fn key ->
        internal?(key)
      end)

    symbol_keys = Map.keys(map) |> Enum.filter(&is_symbol/1)
    string_keys ++ symbol_keys
  end

  defp numeric_index_keys(size) when size <= 0, do: []
  defp numeric_index_keys(size), do: Enum.map(0..(size - 1), &Integer.to_string/1)
end
