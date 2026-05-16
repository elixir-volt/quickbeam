defmodule QuickBEAM.VM.Runtime.Set do
  @moduledoc "JS `Set` and `WeakSet` built-ins: constructor, `add`/`has`/`delete`, `forEach`, and iteration."

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Collections

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, this ->
      {ref, instance_proto} =
        case this do
          {:obj, this_ref} ->
            existing = Heap.get_obj(this_ref, %{})
            {this_ref, Map.get(existing, proto(), Runtime.global_class_proto("Set"))}

          _ ->
            {make_ref(), Runtime.global_class_proto("Set")}
        end

      items =
        args |> arg(0, nil) |> Heap.to_list() |> Enum.map(&normalize_set_value/1) |> Enum.uniq()

      Heap.put_obj(ref, set_object(ref, items, instance_proto))
      {:obj, ref}
    end
  end

  @doc "Helper for js `set` and `weakset` built-ins: constructor, `add`/`has`/`delete`, `foreach`, and iteration."
  def weak_constructor do
    fn args, this ->
      {ref, instance_proto} =
        case this do
          {:obj, this_ref} ->
            existing = Heap.get_obj(this_ref, %{})
            {this_ref, Map.get(existing, proto(), Runtime.global_class_proto("WeakSet"))}

          _ ->
            {make_ref(), Runtime.global_class_proto("WeakSet")}
        end

      Heap.put_obj(ref, %{
        set_data() => [],
        "size" => 0,
        :weak => true,
        proto() => instance_proto
      })

      set = {:obj, ref}

      case args do
        [] ->
          set

        [source | _] when source in [nil, :undefined] ->
          set

        [source | _] ->
          prototype_adder = Get.get(Runtime.global_class_proto("WeakSet"), "add")

          unless Builtin.callable?(prototype_adder) do
            JSThrow.type_error!("WeakSet.prototype.add is not callable")
          end

          adder = Get.get(set, "add")
          construct_weak_set_from_iterable(source, set, adder)
          set
      end
    end
  end

  @doc "Returns the SetData size for Set.prototype.size."
  def size(this), do: this |> require_strong_set_ref!() |> data() |> length()

  @doc "Returns a prototype property value for the given JavaScript property key."
  def proto_property("has"), do: {:builtin, "has", &has/2}
  def proto_property("add"), do: {:builtin, "add", &add/2}
  def proto_property("delete"), do: {:builtin, "delete", &delete/2}
  def proto_property("clear"), do: {:builtin, "clear", &clear/2}
  def proto_property("values"), do: {:builtin, "values", &values/2}
  def proto_property("keys"), do: proto_property("values")
  def proto_property("entries"), do: {:builtin, "entries", &entries/2}
  def proto_property({:symbol, "Symbol.iterator"}), do: proto_property("values")
  def proto_property("forEach"), do: {:builtin, "forEach", &for_each/2}
  def proto_property("difference"), do: {:builtin, "difference", &difference/2}
  def proto_property("intersection"), do: {:builtin, "intersection", &intersection/2}
  def proto_property("union"), do: {:builtin, "union", &union/2}

  def proto_property("symmetricDifference"),
    do: {:builtin, "symmetricDifference", &symmetric_difference/2}

  def proto_property("isSubsetOf"), do: {:builtin, "isSubsetOf", &subset?/2}
  def proto_property("isSupersetOf"), do: {:builtin, "isSupersetOf", &superset?/2}
  def proto_property("isDisjointFrom"), do: {:builtin, "isDisjointFrom", &disjoint?/2}
  def proto_property(_), do: :undefined

  def weak_proto_property("has"), do: {:builtin, "has", &weak_has/2}
  def weak_proto_property("add"), do: {:builtin, "add", &weak_add/2}
  def weak_proto_property("delete"), do: {:builtin, "delete", &weak_delete/2}
  def weak_proto_property(_), do: :undefined

  defp set_object(_set_ref, items, instance_proto) do
    %{
      set_data() => items,
      "size" => length(items),
      proto() => instance_proto
    }
  end

  defp data(set_ref), do: Heap.get_obj(set_ref, %{}) |> Map.get(set_data(), [])

  defp construct_weak_set_from_iterable({:obj, _} = iterable, set, adder) do
    iterator_method = Get.get(iterable, {:symbol, "Symbol.iterator"})

    unless Builtin.callable?(iterator_method) do
      JSThrow.type_error!("object is not iterable")
    end

    iterator = call_with_this(iterator_method, [], iterable)
    construct_weak_set_from_iterator(iterator, set, adder)
  end

  defp construct_weak_set_from_iterable(list, set, adder) when is_list(list) do
    Enum.each(list, &call_with_this(adder, [&1], set))
  end

  defp construct_weak_set_from_iterable(_, _set, _adder),
    do: JSThrow.type_error!("object is not iterable")

  defp construct_weak_set_from_iterator(iterator, set, adder) do
    next_fn = Get.get(iterator, "next")

    unless Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = call_with_this(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      call_iterator_return(iterator)
      JSThrow.type_error!("Iterator result is not an object")
    end

    unless Get.get(result, "done") == true do
      value = Get.get(result, "value")

      try do
        call_with_this(adder, [value], set)
      catch
        {:js_throw, _} = thrown ->
          call_iterator_return(iterator)
          throw(thrown)
      end

      construct_weak_set_from_iterator(iterator, set, adder)
    end
  end

  defp normalize_set_value(value) when is_float(value) and value == 0.0, do: 0
  defp normalize_set_value(value), do: value


  defp other_size(other) do
    case Get.get(other, "size") do
      {:bigint, _} -> JSThrow.type_error!("set-like object size must be a number")
      size -> Runtime.to_number(size)
    end
  end

  defp validate_set_like!({:obj, _} = other) do
    size = other_size(other)
    has_fn = Get.get(other, "has")
    keys_fn = Get.get(other, "keys")

    cond do
      size == :nan or size == :NaN ->
        JSThrow.type_error!("can't convert to number: .size is NaN")

      size == :neg_infinity ->
        JSThrow.range_error!("invalid .size: must be non-negative")

      not is_number(size) ->
        JSThrow.type_error!("set-like object size must be a number")

      size < 0 ->
        JSThrow.range_error!("invalid .size: must be non-negative")

      not QuickBEAM.VM.Builtin.callable?(has_fn) ->
        JSThrow.type_error!("set-like object has must be callable")

      not QuickBEAM.VM.Builtin.callable?(keys_fn) ->
        JSThrow.type_error!("set-like object keys must be callable")

      true ->
        %{object: other, size: size, has: has_fn, keys: keys_fn}
    end
  end

  defp validate_set_like!(_), do: JSThrow.type_error!("set-like object must be an object")

  defp other_has_with(has_fn, other, value) do
    value = normalize_set_value(value)

    case has_fn do
      {:builtin, _, fun} when is_function(fun) -> fun.([value], other) == true
      fun -> Runtime.call_callback(fun, [value]) == true
    end
  end

  defp other_data_from_record(%{object: {:obj, ref}} = record) do
    map = Heap.get_obj(ref, %{})

    case Map.get(map, set_data()) do
      items when is_list(items) -> items
      _ -> iterate_setlike(record.keys, record.object)
    end
  end

  defp iterate_setlike(keys_fn, _other) when keys_fn in [:undefined, nil], do: []

  defp iterate_setlike(keys_fn, other) do
    iterator = call_with_this(keys_fn, [], other)
    collect_iterator(iterator, [])
  end

  defp collect_iterator(iterator, acc) do
    next_fn = Get.get(iterator, "next")
    collect_iterator_loop(iterator, next_fn, acc)
  end

  defp collect_iterator_loop(iterator, next_fn, acc) do
    result = call_with_this(next_fn, [], iterator)

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      value = result |> Get.get("value") |> normalize_set_value()
      collect_iterator_loop(iterator, next_fn, [value | acc])
    end
  end

  defp call_with_this(fun, args, this) do
    case fun do
      {:builtin, _, callback} when is_function(callback) ->
        callback.(args, this)

      %QuickBEAM.VM.Function{} = function ->
        Interpreter.invoke_with_receiver(function, args, Runtime.gas_budget(), this)

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        Interpreter.invoke_with_receiver(closure, args, Runtime.gas_budget(), this)

      _ ->
        Runtime.call_callback(fun, args)
    end
  end

  defp difference([other | _], this),
    do: this |> require_strong_set_ref!() |> set_difference(other)

  defp difference(_, this), do: require_strong_set_ref!(this)

  defp set_difference(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)

    result =
      if length(items) <= record.size do
        Enum.reject(items, &other_has_with(record.has, record.object, &1))
      else
        items -- other_data_from_record(record)
      end

    constructor().([result], nil)
  end

  defp intersection([other | _], this),
    do: this |> require_strong_set_ref!() |> set_intersection(other)

  defp intersection(_, this), do: require_strong_set_ref!(this)

  defp set_intersection(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)

    result =
      if length(items) <= record.size do
        Enum.filter(items, &other_has_with(record.has, record.object, &1))
      else
        record
        |> other_data_from_record()
        |> Enum.filter(&(&1 in items))
      end

    constructor().([result], nil)
  end

  defp union([other | _], this), do: this |> require_strong_set_ref!() |> set_union(other)
  defp union(_, this), do: require_strong_set_ref!(this)

  defp set_union(set_ref, other) do
    record = validate_set_like!(other)
    constructor().([Enum.uniq(data(set_ref) ++ other_data_from_record(record))], nil)
  end

  defp symmetric_difference([other | _], this),
    do: this |> require_strong_set_ref!() |> set_symmetric_difference(other)

  defp symmetric_difference(_, this), do: require_strong_set_ref!(this)

  defp set_symmetric_difference(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)
    other_items = other_data_from_record(record)
    constructor().([(items -- other_items) ++ (other_items -- items)], nil)
  end

  defp subset?([other | _], this), do: this |> require_strong_set_ref!() |> set_subset?(other)
  defp subset?(_, this), do: require_strong_set_ref!(this)

  defp set_subset?(set_ref, other) do
    record = validate_set_like!(other)

    length(data(set_ref)) <= record.size and
      live_subset?(set_ref, record, 0)
  end

  defp live_subset?(set_ref, record, index) do
    items = data(set_ref)

    if index >= length(items) do
      true
    else
      other_has_with(record.has, record.object, Enum.at(items, index)) and
        live_subset?(set_ref, record, index + 1)
    end
  end

  defp superset?([other | _], this), do: this |> require_strong_set_ref!() |> set_superset?(other)
  defp superset?(_, this), do: require_strong_set_ref!(this)

  defp set_superset?(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)

    if is_number(record.size) and length(items) >= record.size do
      iterator = call_with_this(record.keys, [], record.object)
      iterate_check_all(iterator, items)
    else
      false
    end
  end

  defp disjoint?([other | _], this), do: this |> require_strong_set_ref!() |> set_disjoint?(other)
  defp disjoint?(_, this), do: require_strong_set_ref!(this)

  defp set_disjoint?(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)

    if is_number(record.size) and length(items) > record.size do
      iterator = call_with_this(record.keys, [], record.object)
      iterate_check_none(iterator, items)
    else
      not Enum.any?(items, fn value -> other_has_with(record.has, record.object, value) end)
    end
  end

  defp iterate_check_all(iterator, set_data) do
    next_fn = Get.get(iterator, "next")
    do_iterate_check(iterator, next_fn, set_data, :all)
  end

  defp iterate_check_none(iterator, set_data) do
    next_fn = Get.get(iterator, "next")
    do_iterate_check(iterator, next_fn, set_data, :none)
  end

  defp do_iterate_check(iterator, next_fn, set_data, mode) do
    result = call_with_this(next_fn, [], iterator)

    if Get.get(result, "done") == true do
      true
    else
      value = result |> Get.get("value") |> normalize_set_value()
      in_set = value in set_data

      case mode do
        :all ->
          if in_set do
            do_iterate_check(iterator, next_fn, set_data, mode)
          else
            call_iterator_return(iterator)
            false
          end

        :none ->
          if in_set do
            call_iterator_return(iterator)
            false
          else
            do_iterate_check(iterator, next_fn, set_data, mode)
          end
      end
    end
  end

  defp call_iterator_return(iterator) do
    return_fn = Get.get(iterator, "return")

    if return_fn != :undefined and return_fn != nil do
      call_with_this(return_fn, [], iterator)
    end
  end

  defp require_weak_set_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, set_data()) and is_map_key(map, :weak) -> ref
      _ -> JSThrow.type_error!("Method requires a WeakSet")
    end
  end

  defp require_weak_set_ref!(_), do: JSThrow.type_error!("Method requires a WeakSet")

  defp require_strong_set_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, set_data()) and not is_map_key(map, :weak) ->
        ref

      _ ->
        JSThrow.type_error!("Method requires a Set")
    end
  end

  defp require_strong_set_ref!(_), do: JSThrow.type_error!("Method requires a Set")

  defp has([value | _], this) do
    ref = require_strong_set_ref!(this)
    items = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    normalize_set_value(value) in items
  end

  defp has(_, this), do: require_strong_set_ref!(this)

  defp add([value | _], this) do
    ref = require_strong_set_ref!(this)
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: Collections.validate_weak_key!(value, "WeakSet")
    value = normalize_set_value(value)
    items = Map.get(obj, set_data(), [])

    unless value in items do
      new_items = items ++ [value]

      Heap.put_obj(ref, %{
        obj
        | set_data() => new_items,
          "size" => length(new_items)
      })
    end

    {:obj, ref}
  end

  defp add(_, this), do: require_strong_set_ref!(this)

  defp delete([value | _], this) do
    ref = require_strong_set_ref!(this)
    obj = Heap.get_obj(ref, %{})
    value = normalize_set_value(value)
    items = Map.get(obj, set_data(), [])
    new_items = List.delete(items, value)

    Heap.put_obj(ref, %{
      obj
      | set_data() => new_items,
        "size" => length(new_items)
    })

    value in items
  end

  defp delete(_, this), do: require_strong_set_ref!(this)

  defp weak_has([value | _], this) do
    ref = require_weak_set_ref!(this)
    items = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    value in items
  end

  defp weak_has(_, this), do: require_weak_set_ref!(this)

  defp weak_add([value | _], this) do
    ref = require_weak_set_ref!(this)
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: Collections.validate_weak_key!(value, "WeakSet")
    items = Map.get(obj, set_data(), [])

    unless value in items do
      Heap.put_obj(ref, %{obj | set_data() => items ++ [value], "size" => length(items) + 1})
    end

    {:obj, ref}
  end

  defp weak_add(_, this) do
    require_weak_set_ref!(this)
    JSThrow.type_error!("invalid value used as WeakSet key")
  end

  defp weak_delete([value | _], this) do
    ref = require_weak_set_ref!(this)
    obj = Heap.get_obj(ref, %{})
    items = Map.get(obj, set_data(), [])
    new_items = List.delete(items, value)
    Heap.put_obj(ref, %{obj | set_data() => new_items, "size" => length(new_items)})
    value in items
  end

  defp weak_delete(_, this), do: require_weak_set_ref!(this)

  defp clear(_, this) do
    ref = require_strong_set_ref!(this)
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | set_data() => [], "size" => 0})
    :undefined
  end

  defp values(_, this) do
    ref = require_strong_set_ref!(this)
    make_set_iterator(ref, :values, "Set Iterator")
  end

  defp entries(_, this) do
    ref = require_strong_set_ref!(this)
    make_set_iterator(ref, :entries, "Set Iterator")
  end

  defp make_set_iterator(ref, mode, tag) do
    state_ref = make_ref()
    Process.put(state_ref, {[], false})
    {:obj, iter_ref} = iter = Heap.wrap(%{})

    next_fn =
      {:builtin, "next",
       fn _, this ->
         {set_ref, iter_state, iter_mode} = require_set_iterator!(this)
         next_set_iterator_value(set_ref, iter_state, iter_mode)
       end}

    proto =
      Heap.wrap(%{
        "__proto__" => QuickBEAM.VM.Runtime.global_class_proto("Iterator"),
        "next" => next_fn,
        {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _, this -> this end},
        {:symbol, "Symbol.toStringTag"} => tag
      })

    with {:obj, proto_ref} <- proto do
      Heap.put_prop_desc(proto_ref, "next", PropertyDescriptor.method())
      Heap.put_prop_desc(proto_ref, {:symbol, "Symbol.iterator"}, PropertyDescriptor.method())

      Heap.put_prop_desc(
        proto_ref,
        {:symbol, "Symbol.toStringTag"},
        PropertyDescriptor.hidden_readonly()
      )
    end

    Heap.put_obj(iter_ref, %{
      "__proto__" => proto,
      "__set_iterator_ref__" => ref,
      "__set_iterator_state__" => state_ref,
      "__set_iterator_mode__" => mode,
      "next" => next_fn,
      {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _, this -> this end}
    })

    iter
  end

  defp require_set_iterator!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{
        "__set_iterator_ref__" => set_ref,
        "__set_iterator_state__" => state_ref,
        "__set_iterator_mode__" => mode
      } ->
        {set_ref, state_ref, mode}

      _ ->
        JSThrow.type_error!("Set Iterator next called on incompatible receiver")
    end
  end

  defp require_set_iterator!(_),
    do: JSThrow.type_error!("Set Iterator next called on incompatible receiver")

  defp next_set_iterator_value(ref, state_ref, mode) do
    case Process.get(state_ref, {[], false}) do
      {_seen, true} ->
        Heap.wrap(%{"value" => :undefined, "done" => true})

      {seen, false} ->
        case next_set_iterator_key(ref, seen) do
          :done ->
            Process.put(state_ref, {seen, true})
            Heap.wrap(%{"value" => :undefined, "done" => true})

          value ->
            Process.put(state_ref, {[value | seen], false})
            Heap.wrap(%{"value" => set_iterator_result(mode, value), "done" => false})
        end
    end
  end

  defp next_set_iterator_key(ref, seen) do
    ref
    |> Heap.get_obj(%{})
    |> Map.get(set_data(), [])
    |> Enum.find(:done, &(&1 not in seen))
  end

  defp set_iterator_result(:entries, value), do: Heap.wrap([value, value])
  defp set_iterator_result(_mode, value), do: value

  defp for_each([callback | rest], this) do
    ref = require_strong_set_ref!(this)

    unless QuickBEAM.VM.Builtin.callable?(callback) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = List.first(rest) || :undefined
    for_each_live(ref, callback, this_arg, data(ref))
  end

  defp for_each(_, this) do
    require_strong_set_ref!(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp for_each_live(_ref, _callback, _this_arg, []), do: :undefined

  defp for_each_live(ref, callback, this_arg, [value | _]) do
    if value in data(ref) do
      QuickBEAM.VM.Invocation.invoke_with_receiver(
        callback,
        [value, value, {:obj, ref}],
        this_arg
      )
    end

    for_each_live(ref, callback, this_arg, values_after_current(ref, value))
  end

  defp values_after_current(ref, value) do
    items = data(ref)

    case Enum.find_index(items, &(&1 == value)) do
      nil -> items
      index -> Enum.drop(items, index + 1)
    end
  end
end
