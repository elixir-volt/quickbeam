defmodule QuickBEAM.VM.Runtime.Map do
  @moduledoc "JS `Map` and `WeakMap` built-ins: constructor, `get`/`set`/`has`/`delete`, and iteration."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Collections

  alias QuickBEAM.VM.{Builtin, Invocation, JSThrow}

  @doc "Implements Map.groupBy(items, callbackfn)."
  def group_by(args) do
    items = Builtin.arg(args, 0, :undefined)
    callback = Builtin.arg(args, 1, :undefined)

    if items in [nil, :undefined] do
      JSThrow.type_error!("Cannot convert undefined or null to object")
    end

    unless Builtin.callable?(callback) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    list = group_items(items)
    ref = make_ref()
    groups = %{}
    order = []

    {groups, order} =
      list
      |> Enum.with_index()
      |> Enum.reduce({groups, order}, fn {val, idx}, {g, ord} ->
        key = Invocation.invoke_with_receiver(callback, [val, idx], :undefined)
        normalized_key = if key == -0.0, do: 0, else: key

        case Map.fetch(g, normalized_key) do
          {:ok, existing} ->
            {Map.put(g, normalized_key, existing ++ [val]), ord}

          :error ->
            {Map.put(g, normalized_key, [val]), ord ++ [normalized_key]}
        end
      end)

    result_entries =
      Enum.map(order, fn key -> {key, Heap.wrap(Map.get(groups, key, []))} end)

    result_map = Enum.into(result_entries, %{})
    result_order = Enum.map(result_entries, fn {k, _} -> k end)

    Heap.put_obj(ref, %{
      map_data() => result_map,
      key_order() => Enum.reverse(result_order),
      proto() => Runtime.global_class_proto("Map")
    })

    {:obj, ref}
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, _this ->
      ref = make_ref()

      Heap.put_obj(ref, %{
        map_data() => %{},
        key_order() => [],
        "size" => 0,
        proto() => Runtime.global_class_proto("Map")
      })

      map = {:obj, ref}

      case args do
        [] ->
          map

        [iterable | _] when iterable in [nil, :undefined] ->
          map

        [iterable | _] ->
          prototype_adder = Get.get(Runtime.global_class_proto("Map"), "set")

          unless Builtin.callable?(prototype_adder) do
            JSThrow.type_error!("Map.prototype.set is not callable")
          end

          adder = Get.get(map, "set")
          construct_from_iterable(iterable, map, adder)
          map
      end
    end
  end

  @doc "Helper for js `map` and `weakmap` built-ins: constructor, `get`/`set`/`has`/`delete`, and iteration."
  def weak_constructor do
    fn args, _this ->
      ref = make_ref()

      Heap.put_obj(ref, %{
        map_data() => %{},
        "size" => 0,
        :weak => true,
        proto() => Runtime.global_class_proto("WeakMap")
      })

      map = {:obj, ref}

      case args do
        [] ->
          map

        [iterable | _] when iterable in [nil, :undefined] ->
          map

        [iterable | _] ->
          prototype_adder = Get.get(Runtime.global_class_proto("WeakMap"), "set")

          unless Builtin.callable?(prototype_adder) do
            JSThrow.type_error!("WeakMap.prototype.set is not callable")
          end

          adder = Get.get(map, "set")
          construct_from_iterable(iterable, map, adder)
          map
      end
    end
  end

  @doc "Returns the MapData size for Map.prototype.size."
  def size(this), do: this |> require_strong_map_ref!() |> data() |> map_size()

  @doc "Returns a prototype property value for the given JavaScript property key."
  def proto_property("get"), do: {:builtin, "get", &get/2}
  def proto_property("set"), do: {:builtin, "set", &set/2}
  def proto_property("has"), do: {:builtin, "has", &has/2}
  def proto_property("delete"), do: {:builtin, "delete", &delete/2}
  def proto_property("clear"), do: {:builtin, "clear", &clear/2}
  def proto_property("keys"), do: {:builtin, "keys", &keys/2}
  def proto_property("values"), do: {:builtin, "values", &values/2}
  def proto_property("entries"), do: {:builtin, "entries", &entries/2}
  def proto_property({:symbol, "Symbol.iterator"}), do: proto_property("entries")
  def proto_property("forEach"), do: {:builtin, "forEach", &for_each/2}
  def proto_property("getOrInsert"), do: {:builtin, "getOrInsert", &get_or_insert/2}

  def proto_property("getOrInsertComputed"),
    do: {:builtin, "getOrInsertComputed", &get_or_insert_computed/2}

  def proto_property("size") do
    {:accessor, {:builtin, "get size", fn _args, this -> size(this) end}, nil}
  end

  def proto_property(_), do: :undefined

  def weak_proto_property("get"), do: {:builtin, "get", &weak_get/2}
  def weak_proto_property("set"), do: {:builtin, "set", &weak_set/2}
  def weak_proto_property("has"), do: {:builtin, "has", &weak_has/2}
  def weak_proto_property("delete"), do: {:builtin, "delete", &weak_delete/2}
  def weak_proto_property("getOrInsert"), do: {:builtin, "getOrInsert", &weak_get_or_insert/2}

  def weak_proto_property("getOrInsertComputed"),
    do: {:builtin, "getOrInsertComputed", &weak_get_or_insert_computed/2}

  def weak_proto_property(_), do: :undefined

  defp group_items(list) when is_list(list), do: list
  defp group_items({:qb_arr, arr}), do: :array.to_list(arr)
  defp group_items(text) when is_binary(text), do: String.codepoints(text)

  defp group_items({:obj, _} = obj) do
    iterator_method = Get.get(obj, {:symbol, "Symbol.iterator"})

    unless Builtin.callable?(iterator_method) do
      JSThrow.type_error!("object is not iterable")
    end

    iterator = Invocation.invoke_with_receiver(iterator_method, [], obj)
    iterator_to_list(iterator, [])
  end

  defp group_items(_), do: JSThrow.type_error!("object is not iterable")

  defp construct_from_iterable(list, map, adder) when is_list(list) do
    Enum.each(list, fn entry ->
      {key, value} = require_entry_pair(entry)
      Invocation.invoke_with_receiver(adder, [key, value], map)
    end)
  end

  defp construct_from_iterable({:qb_arr, arr}, map, adder) do
    construct_from_iterable(:array.to_list(arr), map, adder)
  end

  defp construct_from_iterable({:obj, _} = iterable, map, adder) do
    iterator_method = Get.get(iterable, {:symbol, "Symbol.iterator"})

    unless Builtin.callable?(iterator_method) do
      JSThrow.type_error!("object is not iterable")
    end

    iterator = Invocation.invoke_with_receiver(iterator_method, [], iterable)
    construct_from_iterator(iterator, map, adder)
  end

  defp construct_from_iterable(_, _map, _adder), do: JSThrow.type_error!("object is not iterable")

  defp construct_from_iterator(iterator, map, adder) do
    next_fn = Get.get(iterator, "next")

    unless Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = Invocation.invoke_with_receiver(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      close_iterator(iterator)
      JSThrow.type_error!("Iterator result is not an object")
    end

    unless Get.get(result, "done") == true do
      entry = Get.get(result, "value")

      try do
        {key, value} = require_entry_pair(entry)
        Invocation.invoke_with_receiver(adder, [key, value], map)
      catch
        {:js_throw, _} = thrown ->
          close_iterator(iterator)
          throw(thrown)
      end

      construct_from_iterator(iterator, map, adder)
    end
  end

  defp close_iterator(iterator) do
    case Get.get(iterator, "return") do
      return_fn when return_fn not in [nil, :undefined] ->
        if Builtin.callable?(return_fn),
          do: Invocation.invoke_with_receiver(return_fn, [], iterator)

      _ ->
        :undefined
    end
  end

  defp iterator_to_list(iterator, acc) do
    next_fn = Get.get(iterator, "next")

    unless Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = Invocation.invoke_with_receiver(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      JSThrow.type_error!("Iterator result is not an object")
    end

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      iterator_to_list(iterator, [Get.get(result, "value") | acc])
    end
  end

  defp require_weak_map_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, map_data()) and is_map_key(map, :weak) -> ref
      _ -> JSThrow.type_error!("Method requires a WeakMap")
    end
  end

  defp require_weak_map_ref!(_), do: JSThrow.type_error!("Method requires a WeakMap")

  defp require_strong_map_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, map_data()) and not is_map_key(map, :weak) ->
        ref

      _ ->
        JSThrow.type_error!("Method requires a Map")
    end
  end

  defp require_strong_map_ref!(_), do: JSThrow.type_error!("Method requires a Map")

  defp data(ref), do: Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

  defp normalize_key(k) when is_float(k) and k == trunc(k), do: trunc(k)
  defp normalize_key(k), do: k

  defp get([key | _], this) do
    ref = require_strong_map_ref!(this)
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.get(data, normalize_key(key), :undefined)
  end

  defp get(_, this), do: require_strong_map_ref!(this)

  defp get_or_insert([key, value | _], this) do
    ref = require_strong_map_ref!(this)
    key = normalize_key(key)
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})

    case Map.fetch(data, key) do
      {:ok, existing} ->
        existing

      :error ->
        insert_map_entry(ref, obj, key, value)
        value
    end
  end

  defp get_or_insert(_, this), do: require_strong_map_ref!(this)

  defp get_or_insert_computed([key, callback | _], this) do
    ref = require_strong_map_ref!(this)

    unless Builtin.callable?(callback) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    key = normalize_key(key)
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})

    case Map.fetch(data, key) do
      {:ok, existing} ->
        existing

      :error ->
        value = Invocation.invoke_with_receiver(callback, [key], :undefined)
        obj = Heap.get_obj(ref, %{})
        insert_map_entry(ref, obj, key, value)
        value
    end
  end

  defp get_or_insert_computed(_, this), do: require_strong_map_ref!(this)

  defp insert_map_entry(ref, obj, key, value) do
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), [])
    order = if Map.has_key?(data, key), do: order, else: [key | order]
    new_data = Map.put(data, key, value)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{map_data() => new_data, "size" => map_size(new_data), key_order() => order})
    )
  end

  defp set([key, val | _], this) do
    ref = require_strong_map_ref!(this)
    obj = Heap.get_obj(ref, %{})
    key = normalize_key(key)
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), [])
    order = if Map.has_key?(data, key), do: order, else: [key | order]
    new_data = Map.put(data, key, val)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{
        map_data() => new_data,
        "size" => map_size(new_data),
        key_order() => order
      })
    )

    {:obj, ref}
  end

  defp set(_, this), do: require_strong_map_ref!(this)

  defp has([key | _], this) do
    ref = require_strong_map_ref!(this)
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.has_key?(data, normalize_key(key))
  end

  defp has(_, this), do: require_strong_map_ref!(this)

  defp delete([key | _], this) do
    ref = require_strong_map_ref!(this)
    key = normalize_key(key)
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    new_data = Map.delete(data, key)
    order = Map.get(obj, key_order(), []) |> List.delete(key)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{
        map_data() => new_data,
        "size" => map_size(new_data),
        key_order() => order
      })
    )

    Map.has_key?(data, key)
  end

  defp delete(_, this), do: require_strong_map_ref!(this)

  defp weak_get([key | _], this) do
    ref = require_weak_map_ref!(this)
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.get(data, key, :undefined)
  end

  defp weak_get(_, this), do: require_weak_map_ref!(this)

  defp weak_set([key, value | _], this) do
    ref = require_weak_map_ref!(this)
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: Collections.validate_weak_key!(key, "WeakMap")
    data = Map.get(obj, map_data(), %{})
    new_data = Map.put(data, key, value)
    Heap.put_obj(ref, Map.merge(obj, %{map_data() => new_data, "size" => map_size(new_data)}))
    {:obj, ref}
  end

  defp weak_set(_, this), do: require_weak_map_ref!(this)

  defp weak_has([key | _], this) do
    ref = require_weak_map_ref!(this)
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.has_key?(data, key)
  end

  defp weak_has(_, this), do: require_weak_map_ref!(this)

  defp weak_delete([key | _], this) do
    ref = require_weak_map_ref!(this)
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    new_data = Map.delete(data, key)
    Heap.put_obj(ref, Map.merge(obj, %{map_data() => new_data, "size" => map_size(new_data)}))
    Map.has_key?(data, key)
  end

  defp weak_delete(_, this), do: require_weak_map_ref!(this)

  defp weak_get_or_insert([key | rest], this) do
    value = List.first(rest, :undefined)
    ref = require_weak_map_ref!(this)
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: Collections.validate_weak_key!(key, "WeakMap")
    data = Map.get(obj, map_data(), %{})

    case Map.fetch(data, key) do
      {:ok, existing} ->
        existing

      :error ->
        Heap.put_obj(
          ref,
          Map.merge(obj, %{map_data() => Map.put(data, key, value), "size" => map_size(data) + 1})
        )

        value
    end
  end

  defp weak_get_or_insert(_, this), do: require_weak_map_ref!(this)

  defp weak_get_or_insert_computed([key, callback | _], this) do
    ref = require_weak_map_ref!(this)
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: Collections.validate_weak_key!(key, "WeakMap")

    unless Builtin.callable?(callback) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    data = Map.get(obj, map_data(), %{})

    case Map.fetch(data, key) do
      {:ok, existing} ->
        existing

      :error ->
        value = Invocation.invoke_with_receiver(callback, [key], :undefined)
        obj = Heap.get_obj(ref, %{})
        data = Map.get(obj, map_data(), %{})

        Heap.put_obj(
          ref,
          Map.merge(obj, %{map_data() => Map.put(data, key, value), "size" => map_size(data) + 1})
        )

        value
    end
  end

  defp weak_get_or_insert_computed(_, this), do: require_weak_map_ref!(this)

  defp clear(_, this) do
    ref = require_strong_map_ref!(this)
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | map_data() => %{}, "size" => 0, key_order() => []})
    :undefined
  end

  defp keys(_, this) do
    ref = require_strong_map_ref!(this)
    make_map_iterator(ref, :keys)
  end

  defp values(_, this) do
    ref = require_strong_map_ref!(this)
    make_map_iterator(ref, :values)
  end

  defp entries(_, this) do
    ref = require_strong_map_ref!(this)
    make_map_iterator(ref, :entries)
  end

  defp make_map_iterator(ref, mode) do
    state_ref = make_ref()
    Process.put(state_ref, ordered_keys(ref))

    next_fn =
      {:builtin, "next",
       fn _, _ ->
         next_map_iterator_value(ref, state_ref, mode)
       end}

    Heap.wrap(%{
      "next" => next_fn,
      {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _, this -> this end}
    })
  end

  defp next_map_iterator_value(ref, state_ref, mode) do
    case next_present_key(ref, Process.get(state_ref, [])) do
      {:done, pending} ->
        Process.put(state_ref, pending)
        Heap.wrap(%{"value" => :undefined, "done" => true})

      {key, pending} ->
        Process.put(state_ref, pending)
        data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

        Heap.wrap(%{
          "value" => map_iterator_result(mode, key, Map.get(data, key)),
          "done" => false
        })
    end
  end

  defp next_present_key(_ref, []), do: {:done, []}

  defp next_present_key(ref, [key | rest]) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

    if Map.has_key?(data, key) do
      {key, rest}
    else
      next_present_key(ref, rest)
    end
  end

  defp map_iterator_result(:keys, key, _value), do: key
  defp map_iterator_result(:values, _key, value), do: value
  defp map_iterator_result(:entries, key, value), do: Heap.wrap([key, value])

  defp require_entry_pair([k, v | _]), do: {k, v}
  defp require_entry_pair([k]), do: {k, :undefined}

  defp require_entry_pair({:obj, _} = entry) do
    {Get.get(entry, "0"), Get.get(entry, "1")}
  end

  defp require_entry_pair({:qb_arr, arr}), do: require_entry_pair(:array.to_list(arr))
  defp require_entry_pair(_), do: JSThrow.type_error!("Iterator value is not an entry object")

  defp for_each([callback | rest], this) do
    ref = require_strong_map_ref!(this)

    unless Builtin.callable?(callback) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = List.first(rest) || :undefined
    for_each_live(ref, callback, this_arg, ordered_keys(ref), [])
  end

  defp for_each(_, this) do
    require_strong_map_ref!(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp for_each_live(_ref, _callback, _this_arg, [], _seen), do: :undefined

  defp for_each_live(ref, callback, this_arg, [key | rest], seen) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

    case Map.fetch(data, key) do
      {:ok, value} ->
        Invocation.invoke_with_receiver(callback, [value, key, {:obj, ref}], this_arg)

      :error ->
        :ok
    end

    for_each_live(ref, callback, this_arg, next_for_each_keys(ref, key, rest), [key | seen])
  end

  defp ordered_keys(ref), do: Heap.get_obj(ref, %{}) |> Map.get(key_order(), []) |> Enum.reverse()

  defp next_for_each_keys(ref, current_key, rest) do
    keys = ordered_keys(ref)
    rest = Enum.filter(rest, &(&1 in keys))

    case List.last(rest) do
      nil ->
        case Enum.find_index(keys, &(&1 == current_key)) do
          nil -> keys
          index -> Enum.drop(keys, index + 1)
        end

      last_rest_key ->
        suffix = keys |> Enum.drop_while(&(&1 != last_rest_key)) |> Enum.drop(1)
        rest ++ (suffix -- rest)
    end
  end
end
