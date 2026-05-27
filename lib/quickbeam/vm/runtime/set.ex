defmodule QuickBEAM.VM.Runtime.Set do
  @moduledoc "JS `Set` and `WeakSet` built-ins: constructor, `add`/`has`/`delete`, `forEach`, and iteration."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1]
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Execution.IteratorState
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.{Collections, InstallerHelpers}

  defintrinsics do
    intrinsic "Set" do
      constructor(constructor(), length: 0, phase: :collections)

      install do
        install_set_builtin(ctor, opts)
      end
    end

    intrinsic "WeakSet" do
      constructor(weak_constructor(), length: 0, phase: :collections)

      install do
        install_weak_set_builtin(ctor, opts)
      end
    end
  end

  static_methods do
    @ecma "24.2.2.2"
    symbol :species do
      get do
        this
      end
    end
  end

  def install_set_builtin(ctor, opts \\ []) do
    object_proto = Keyword.get(opts, :object_proto, Heap.get_object_prototype())

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref, object_proto)

      Builtin.Installer.install_prototype_specs(proto_ref, __MODULE__)
      InstallerHelpers.install_to_string_tag(proto_ref, "Set")
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end

  def install_weak_set_builtin(ctor, opts \\ []) do
    object_proto = Keyword.get(opts, :object_proto, Heap.get_object_prototype())

    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref, object_proto)
      Heap.put_prop_desc(proto_ref, "constructor", PropertyDescriptor.method())
      install_weak_set_methods(proto_ref)
      InstallerHelpers.install_to_string_tag(proto_ref, "WeakSet")
    end)
  end

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

      Heap.put_obj(ref, set_object(ref, [], instance_proto))
      set = {:obj, ref}

      case args do
        [] ->
          set

        [source | _] when is_nullish(source) ->
          set

        [source | _] ->
          adder = Get.get(set, "add")

          unless Builtin.callable?(adder) do
            JSThrow.type_error!("Set.prototype.add is not callable")
          end

          construct_set_from_iterable(source, set, adder)
          set
      end
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

        [source | _] when is_nullish(source) ->
          set

        [source | _] ->
          adder = Get.get(set, "add")

          unless Builtin.callable?(adder) do
            JSThrow.type_error!("WeakSet.prototype.add is not callable")
          end

          construct_weak_set_from_iterable(source, set, adder)
          set
      end
    end
  end

  prototype_methods do
    @ecma "24.2.4.8"
    method "has", length: 1 do
      has(args, this)
    end

    @ecma "24.2.4.1"
    method "add", length: 1 do
      add(args, this)
    end

    @ecma "24.2.4.4"
    method "delete", length: 1 do
      delete(args, this)
    end

    @ecma "24.2.4.2"
    method "clear", length: 0 do
      clear(args, this)
    end

    @ecma "24.2.4.17"
    method "values", length: 0 do
      values(args, this)
    end

    @ecma "24.2.4.13"
    method "keys", length: 0 do
      values(args, this)
    end

    @ecma "24.2.4.5"
    method "entries", length: 0 do
      entries(args, this)
    end

    @ecma "24.2.4.18"
    symbol :iterator do
      method length: 0 do
        values(args, this)
      end
    end

    @ecma "24.2.4.6"
    method "forEach", length: 1 do
      for_each(args, this)
    end

    @ecma "24.2.4.3"
    method "difference", length: 1 do
      difference(args, this)
    end

    @ecma "24.2.4.9"
    method "intersection", length: 1 do
      intersection(args, this)
    end

    @ecma "24.2.4.16"
    method "union", length: 1 do
      union(args, this)
    end

    @ecma "24.2.4.15"
    method "symmetricDifference", length: 1 do
      symmetric_difference(args, this)
    end

    @ecma "24.2.4.10"
    method "isSubsetOf", length: 1 do
      subset?(args, this)
    end

    @ecma "24.2.4.11"
    method "isSupersetOf", length: 1 do
      superset?(args, this)
    end

    @ecma "24.2.4.9"
    method "isDisjointFrom", length: 1 do
      disjoint?(args, this)
    end

    @ecma "24.2.4.14"
    getter "size" do
      size(this)
    end
  end

  @doc "Returns the SetData size for Set.prototype.size."
  def size(this), do: this |> require_strong_set_ref!() |> data() |> length()

  defp install_weak_set_methods(proto_ref) do
    for name <- ~w(add has delete) do
      Heap.put_obj_key(proto_ref, name, weak_proto_property(name))
      Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.method())
    end
  end

  def weak_proto_property("has"), do: {:builtin, "has", &weak_has/2}
  def weak_proto_property("add"), do: {:builtin, "add", &weak_add/2}
  def weak_proto_property("delete"), do: {:builtin, "delete", &weak_delete/2}
  def weak_proto_property(_), do: :undefined

  defp set_object(_set_ref, items, instance_proto) do
    entries = Enum.with_index(items, 1) |> Enum.map(fn {value, id} -> {id, value, true} end)

    %{
      set_data() => items,
      set_entry_data() => entries,
      set_next_entry_id() => length(items) + 1,
      "size" => length(items),
      proto() => instance_proto
    }
  end

  defp create_set_result(items) do
    ref = make_ref()
    Heap.put_obj(ref, set_object(ref, Enum.uniq(items), Runtime.global_class_proto("Set")))
    {:obj, ref}
  end

  defp data(set_ref), do: Heap.get_obj(set_ref, %{}) |> Map.get(set_data(), [])

  defp set_entry_data, do: "__set_entry_data__"
  defp set_next_entry_id, do: "__set_next_entry_id__"

  defp construct_set_from_iterable({:obj, _} = iterable, set, adder) do
    iterator_method = Get.get(iterable, {:symbol, "Symbol.iterator"})

    unless Builtin.callable?(iterator_method) do
      JSThrow.type_error!("object is not iterable")
    end

    iterator = call_with_this(iterator_method, [], iterable)
    construct_set_from_iterator(iterator, set, adder)
  end

  defp construct_set_from_iterable(list, set, adder) when is_list(list) do
    Enum.each(list, &call_with_this(adder, [&1], set))
  end

  defp construct_set_from_iterable(_, _set, _adder),
    do: JSThrow.type_error!("object is not iterable")

  defp construct_set_from_iterator(iterator, set, adder) do
    next_fn = Get.get(iterator, "next")

    unless Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    try do
      construct_set_iterator_loop(iterator, next_fn, set, adder)
    catch
      {:js_throw, _} = thrown ->
        call_iterator_return(iterator)
        throw(thrown)
    end
  end

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

    try do
      construct_set_iterator_loop(iterator, next_fn, set, adder)
    catch
      {:js_throw, _} = thrown ->
        call_iterator_return(iterator)
        throw(thrown)
    end
  end

  defp construct_set_iterator_loop(iterator, next_fn, set, adder) do
    result = call_with_this(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      JSThrow.type_error!("Iterator result is not an object")
    end

    unless Get.get(result, "done") == true do
      value = Get.get(result, "value")
      call_with_this(adder, [value], set)
      construct_set_iterator_loop(iterator, next_fn, set, adder)
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
    call_with_this(has_fn, [normalize_set_value(value)], other) == true
  end

  defp other_data_from_record(%{keys: {:builtin, name, _}, object: {:obj, ref}} = record)
       when name in ["keys", "values"] do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, set_data()) do
          items when is_list(items) -> items
          _ -> iterate_setlike(record.keys, record.object)
        end

      _other ->
        iterate_setlike(record.keys, record.object)
    end
  end

  defp other_data_from_record(record), do: iterate_setlike(record.keys, record.object)

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

  defp call_with_this({:builtin, _, callback}, args, this) when is_function(callback),
    do: callback.(args, this)

  defp call_with_this(fun, args, this),
    do: Invocation.invoke_with_receiver(fun, args, Runtime.gas_budget(), this)

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

    create_set_result(result)
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

    create_set_result(result)
  end

  defp union([other | _], this), do: this |> require_strong_set_ref!() |> set_union(other)
  defp union(_, this), do: require_strong_set_ref!(this)

  defp set_union(set_ref, other) do
    record = validate_set_like!(other)
    create_set_result(Enum.uniq(data(set_ref) ++ other_data_from_record(record)))
  end

  defp symmetric_difference([other | _], this),
    do: this |> require_strong_set_ref!() |> set_symmetric_difference(other)

  defp symmetric_difference(_, this), do: require_strong_set_ref!(this)

  defp set_symmetric_difference(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)

    other_items = other_data_from_record(record)
    current_items = data(set_ref)

    result =
      other_items
      |> Enum.reduce(items, &toggle_symmetric_difference_value(&2, &1, items, current_items))
      |> Enum.reject(&is_nil/1)

    create_set_result(result)
  end

  defp toggle_symmetric_difference_value(result, value, original_items, current_items) do
    cond do
      value in result ->
        List.replace_at(result, Enum.find_index(result, &(&1 == value)), nil)

      value in original_items and value in current_items ->
        result ++ [value]

      value in original_items ->
        List.replace_at(result, Enum.find_index(original_items, &(&1 == value)), value)

      true ->
        result ++ [value]
    end
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
      live_disjoint?(set_ref, record, 0)
    end
  end

  defp live_disjoint?(set_ref, record, index) do
    items = data(set_ref)

    cond do
      index >= length(items) ->
        true

      other_has_with(record.has, record.object, Enum.at(items, index)) ->
        false

      true ->
        live_disjoint?(set_ref, record, index + 1)
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

    if not is_nullish(return_fn) do
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
      next_id = Map.get(obj, set_next_entry_id(), length(Map.get(obj, set_entry_data(), [])) + 1)
      entries = Map.get(obj, set_entry_data(), []) ++ [{next_id, value, true}]

      Heap.put_obj(ref, %{
        obj
        | set_data() => new_items,
          set_entry_data() => entries,
          set_next_entry_id() => next_id + 1,
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
    entries = Enum.map(Map.get(obj, set_entry_data(), []), &delete_set_entry(&1, value))

    Heap.put_obj(ref, %{
      obj
      | set_data() => new_items,
        set_entry_data() => entries,
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
    entries = Enum.map(Map.get(obj, set_entry_data(), []), &clear_set_entry/1)
    Heap.put_obj(ref, %{obj | set_data() => [], set_entry_data() => entries, "size" => 0})
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
    state_ref = IteratorState.new({0, false})
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
    case IteratorState.get(state_ref, {0, false}) do
      {_cursor, true} ->
        Heap.wrap(%{"value" => :undefined, "done" => true})

      {cursor, false} ->
        case next_set_iterator_entry(ref, cursor) do
          :done ->
            IteratorState.put(state_ref, {cursor, true})
            Heap.wrap(%{"value" => :undefined, "done" => true})

          {entry_id, value} ->
            IteratorState.put(state_ref, {entry_id, false})
            Heap.wrap(%{"value" => set_iterator_result(mode, value), "done" => false})
        end
    end
  end

  defp next_set_iterator_entry(ref, cursor) do
    ref
    |> live_set_entries()
    |> Enum.find(:done, fn {entry_id, _value} -> entry_id > cursor end)
  end

  defp set_iterator_result(:entries, value), do: Heap.wrap([value, value])
  defp set_iterator_result(_mode, value), do: value

  defp for_each([callback | rest], this) do
    ref = require_strong_set_ref!(this)

    unless QuickBEAM.VM.Builtin.callable?(callback) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = List.first(rest) || :undefined
    for_each_live(ref, callback, this_arg, 0)
  end

  defp for_each(_, this) do
    require_strong_set_ref!(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp for_each_live(ref, callback, this_arg, cursor) when is_integer(cursor) do
    case next_set_iterator_entry(ref, cursor) do
      :done ->
        :undefined

      {entry_id, value} ->
        QuickBEAM.VM.Invocation.invoke_with_receiver(
          callback,
          [value, value, {:obj, ref}],
          this_arg
        )

        for_each_live(ref, callback, this_arg, entry_id)
    end
  end

  defp live_set_entries(ref) do
    ref
    |> Heap.get_obj(%{})
    |> Map.get(set_entry_data(), [])
    |> Enum.flat_map(fn
      {entry_id, value, true} -> [{entry_id, value}]
      _ -> []
    end)
  end

  defp clear_set_entry({entry_id, value, _live}), do: {entry_id, value, false}

  defp delete_set_entry({entry_id, value, true}, value), do: {entry_id, value, false}
  defp delete_set_entry(entry, _value), do: entry
end
