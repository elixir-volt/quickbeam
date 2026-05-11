defmodule QuickBEAM.VM.Runtime.Set do
  @moduledoc "JS `Set` and `WeakSet` built-ins: constructor, `add`/`has`/`delete`, `forEach`, and iteration."

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Collections

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, _this ->
      ref = make_ref()

      items =
        args |> arg(0, nil) |> Heap.to_list() |> Enum.map(&normalize_set_value/1) |> Enum.uniq()

      Heap.put_obj(ref, set_object(ref, items))
      {:obj, ref}
    end
  end

  @doc "Helper for js `set` and `weakset` built-ins: constructor, `add`/`has`/`delete`, `foreach`, and iteration."
  def weak_constructor do
    fn args, _this ->
      ref = make_ref()

      items =
        case args do
          [source | _] ->
            Heap.to_list(source)
            |> Enum.each(&Collections.validate_weak_key!(&1, "WeakSet"))

            Heap.to_list(source)

          _ ->
            []
        end

      Heap.put_obj(ref, %{set_data() => items, "size" => length(items), :weak => true})
      {:obj, ref}
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

  defp set_object(_set_ref, items) do
    %{
      set_data() => items,
      "size" => length(items),
      proto() => Runtime.global_class_proto("Set")
    }
  end

  defp data(set_ref), do: Heap.get_obj(set_ref, %{}) |> Map.get(set_data(), [])

  defp normalize_set_value(value) when is_float(value) and value == 0.0, do: 0
  defp normalize_set_value(value), do: value

  defp other_data(other) do
    case other do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        case Map.get(map, set_data()) do
          items when is_list(items) ->
            items

          _ ->
            other
            |> Get.get("keys")
            |> iterate_setlike(other)
        end

      _ ->
        []
    end
  end

  defp other_size(other) do
    case other do
      {:obj, _} ->
        case Get.get(other, "size") do
          {:bigint, _} -> JSThrow.type_error!("set-like object size must be a number")
          size -> Runtime.to_number(size)
        end

      _ ->
        0
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

  defp other_has(other, value) do
    has_fn = Get.get(other, "has")
    other_has_with(has_fn, other, value)
  end

  defp other_has_with(has_fn, other, value) do
    value = normalize_set_value(value)

    case has_fn do
      {:builtin, _, fun} when is_function(fun) -> fun.([value], other) == true
      fun -> Runtime.call_callback(fun, [value]) == true
    end
  end

  defp iterate_setlike(keys_fn, _other) when keys_fn in [:undefined, nil], do: []

  defp iterate_setlike(keys_fn, other) do
    iterator = call_with_this(keys_fn, [], other)
    collect_iterator(iterator, [])
  end

  defp collect_iterator(iterator, acc) do
    next_fn = Get.get(iterator, "next")
    result = call_with_this(next_fn, [], iterator)

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      value = result |> Get.get("value") |> normalize_set_value()
      collect_iterator(iterator, [value | acc])
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
    validate_set_like!(other)
    items = data(set_ref)

    result =
      if length(items) <= other_size(other) do
        Enum.reject(items, &other_has(other, &1))
      else
        items -- other_data(other)
      end

    constructor().([result], nil)
  end

  defp intersection([other | _], this),
    do: this |> require_strong_set_ref!() |> set_intersection(other)

  defp intersection(_, this), do: require_strong_set_ref!(this)

  defp set_intersection(set_ref, other) do
    validate_set_like!(other)
    items = data(set_ref)

    result =
      if length(items) <= other_size(other) do
        Enum.filter(items, &other_has(other, &1))
      else
        other
        |> other_data()
        |> Enum.filter(&(&1 in items))
      end

    constructor().([result], nil)
  end

  defp union([other | _], this), do: this |> require_strong_set_ref!() |> set_union(other)
  defp union(_, this), do: require_strong_set_ref!(this)

  defp set_union(set_ref, other) do
    validate_set_like!(other)
    constructor().([Enum.uniq(data(set_ref) ++ other_data(other))], nil)
  end

  defp symmetric_difference([other | _], this),
    do: this |> require_strong_set_ref!() |> set_symmetric_difference(other)

  defp symmetric_difference(_, this), do: require_strong_set_ref!(this)

  defp set_symmetric_difference(set_ref, other) do
    validate_set_like!(other)
    items = data(set_ref)
    other_items = other_data(other)
    constructor().([(items -- other_items) ++ (other_items -- items)], nil)
  end

  defp subset?([other | _], this), do: this |> require_strong_set_ref!() |> set_subset?(other)
  defp subset?(_, this), do: require_strong_set_ref!(this)

  defp set_subset?(set_ref, other) do
    record = validate_set_like!(other)
    items = data(set_ref)

    length(items) <= record.size and
      Enum.all?(items, &other_has_with(record.has, record.object, &1))
  end

  defp superset?([other | _], this), do: this |> require_strong_set_ref!() |> set_superset?(other)
  defp superset?(_, this), do: require_strong_set_ref!(this)

  defp set_superset?(set_ref, other) do
    validate_set_like!(other)
    items = data(set_ref)
    size = other_size(other)

    if is_number(size) and length(items) >= size do
      iterator = other |> Get.get("keys") |> call_with_this([], other)
      iterate_check_all(iterator, items)
    else
      false
    end
  end

  defp disjoint?([other | _], this), do: this |> require_strong_set_ref!() |> set_disjoint?(other)
  defp disjoint?(_, this), do: require_strong_set_ref!(this)

  defp set_disjoint?(set_ref, other) do
    validate_set_like!(other)
    items = data(set_ref)
    size = other_size(other)

    if is_number(size) and length(items) > size do
      iterator = other |> Get.get("keys") |> call_with_this([], other)
      iterate_check_none(iterator, items)
    else
      not Enum.any?(items, fn value -> other_has(other, value) end)
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

  defp require_setlike_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, set_data()) -> ref
      _ -> JSThrow.type_error!("Method requires a Set")
    end
  end

  defp require_setlike_ref!(_), do: JSThrow.type_error!("Method requires a Set")

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
    ref = require_setlike_ref!(this)
    items = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    value in items
  end

  defp weak_has(_, this), do: require_setlike_ref!(this)

  defp weak_add([value | _], this) do
    ref = require_setlike_ref!(this)
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: Collections.validate_weak_key!(value, "WeakSet")
    items = Map.get(obj, set_data(), [])

    unless value in items do
      Heap.put_obj(ref, %{obj | set_data() => items ++ [value], "size" => length(items) + 1})
    end

    {:obj, ref}
  end

  defp weak_add(_, this), do: require_setlike_ref!(this)

  defp weak_delete([value | _], this) do
    ref = require_setlike_ref!(this)
    obj = Heap.get_obj(ref, %{})
    items = Map.get(obj, set_data(), [])
    new_items = List.delete(items, value)
    Heap.put_obj(ref, %{obj | set_data() => new_items, "size" => length(new_items)})
    value in items
  end

  defp weak_delete(_, this), do: require_setlike_ref!(this)

  defp clear(_, this) do
    ref = require_strong_set_ref!(this)
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | set_data() => [], "size" => 0})
    :undefined
  end

  defp values(_, this) do
    ref = require_strong_set_ref!(this)

    ref
    |> Heap.get_obj(%{})
    |> Map.get(set_data(), [])
    |> Heap.wrap_iterator()
  end

  defp entries(_, this) do
    ref = require_strong_set_ref!(this)

    ref
    |> Heap.get_obj(%{})
    |> Map.get(set_data(), [])
    |> Enum.map(fn value -> Heap.wrap([value, value]) end)
    |> Heap.wrap_iterator()
  end

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

  defp for_each_live(ref, callback, this_arg, index) do
    items = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])

    if index >= length(items) do
      :undefined
    else
      value = Enum.at(items, index)

      QuickBEAM.VM.Invocation.invoke_with_receiver(
        callback,
        [value, value, {:obj, ref}],
        this_arg
      )

      for_each_live(ref, callback, this_arg, index + 1)
    end
  end
end
