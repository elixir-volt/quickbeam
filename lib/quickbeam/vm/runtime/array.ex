defmodule QuickBEAM.VM.Runtime.Array do
  @moduledoc "Array.prototype and Array static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Delete,
    Get,
    HasProperty,
    OwnProperty,
    PropertyDescriptor,
    Prototype,
    Put
  }

  alias QuickBEAM.VM.PromiseState
  alias QuickBEAM.VM.Runtime

  @max_array_length 4_294_967_295
  @max_safe_integer 9_007_199_254_740_991

  @doc "Builds the JavaScript prototype object for this runtime builtin."
  def prototype do
    mod = __MODULE__
    methods = ~w(push pop shift unshift map filter reduce reduceRight forEach indexOf
      lastIndexOf toString toLocaleString includes slice splice join concat reverse sort
      flat find findIndex findLast findLastIndex some every fill copyWithin entries keys values
      at flatMap toReversed toSorted toSpliced with)

    proto_map =
      Enum.reduce(methods, %{}, fn name, acc ->
        Map.put(
          acc,
          name,
          {:builtin, name,
           fn args, this ->
             {:builtin, _, cb} = mod.proto_property(name)
             cb.(args, this)
           end}
        )
      end)

    sym_iter = {:symbol, "Symbol.iterator"}

    proto_map = Map.put(proto_map, sym_iter, Map.fetch!(proto_map, "values"))

    for name <- ~w(entries keys values) do
      method = Map.fetch!(proto_map, name)
      Heap.put_ctor_static(method, "length", 0)

      Heap.put_ctor_prop_desc(method, "length", PropertyDescriptor.hidden_readonly())
    end

    proto = Heap.wrap(proto_map)
    {:obj, ref} = proto

    for name <- methods do
      Heap.put_prop_desc(ref, name, PropertyDescriptor.method())
    end

    Heap.put_prop_desc(ref, sym_iter, PropertyDescriptor.method())

    unscopables_map = %{
      "copyWithin" => true,
      "entries" => true,
      "fill" => true,
      "find" => true,
      "findIndex" => true,
      "flat" => true,
      "flatMap" => true,
      "includes" => true,
      "keys" => true,
      "values" => true,
      "at" => true,
      "findLast" => true,
      "findLastIndex" => true,
      "toReversed" => true,
      "toSorted" => true,
      "toSpliced" => true
    }

    sym_unscopables = {:symbol, "Symbol.unscopables"}
    Heap.put_obj_key(ref, sym_unscopables, Heap.wrap(unscopables_map))

    Heap.put_prop_desc(ref, sym_unscopables, %{
      writable: false,
      enumerable: false,
      configurable: true
    })

    proto
  end

  # ── Array.prototype dispatch ──

  proto "push" do
    push(this, args)
  end

  proto "pop" do
    pop(this, args)
  end

  proto "shift" do
    shift(this, args)
  end

  proto "unshift" do
    unshift(this, args)
  end

  proto "map" do
    map(this, args)
  end

  proto "filter" do
    filter(this, args)
  end

  proto "reduce" do
    reduce(this, args)
  end

  proto "reduceRight" do
    reduce_right(this, args)
  end

  proto "forEach" do
    for_each(this, args)
  end

  proto "indexOf" do
    index_of(this, args)
  end

  proto "lastIndexOf" do
    last_index_of(this, args)
  end

  proto "toString" do
    array_to_string(this)
  end

  proto "toLocaleString" do
    to_locale_string(this)
  end

  proto "includes" do
    includes(this, args)
  end

  proto "slice" do
    slice(this, args)
  end

  proto "splice" do
    splice(this, args)
  end

  proto "join" do
    join(this, args)
  end

  proto "concat" do
    concat(this, args)
  end

  proto "reverse" do
    reverse(this, args)
  end

  proto "sort" do
    sort(this, args)
  end

  proto "flat" do
    flat(this, args)
  end

  proto "find" do
    find(this, args)
  end

  proto "findIndex" do
    find_index(this, args)
  end

  proto "findLast" do
    find_last(this, args)
  end

  proto "findLastIndex" do
    find_last_index(this, args)
  end

  proto "every" do
    every(this, args)
  end

  proto "some" do
    some(this, args)
  end

  proto "flatMap" do
    flat_map(this, args)
  end

  proto "fill" do
    fill(this, args)
  end

  proto "copyWithin" do
    copy_within(this, args)
  end

  proto "at" do
    require_object_coercible!(this)
    array_at(this, args)
  end

  proto "toReversed" do
    to_reversed(this)
  end

  proto "toSorted" do
    to_sorted(this, args)
  end

  proto "toSpliced" do
    to_spliced(this, args)
  end

  proto "with" do
    array_with(this, args)
  end

  proto "values" do
    require_object_coercible!(this)
    make_array_iterator(this, :values)
  end

  proto "keys" do
    require_object_coercible!(this)
    make_array_iterator(this, :keys)
  end

  proto "entries" do
    require_object_coercible!(this)
    make_array_iterator(this, :entries)
  end

  proto {:symbol, "Symbol.iterator"} do
    require_object_coercible!(this)
    make_array_iterator(this, :values)
  end

  @doc "Returns a prototype property value for the given JavaScript property key."
  def proto_property("constructor") do
    Runtime.global_bindings() |> Map.get("Array", :undefined)
  end

  # ── Array static dispatch ──

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  static "isArray" do
    is_array(hd(args))
  end

  @max_proxy_depth 1_000_000

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array(val, depth \\ 0)

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array(_, depth) when depth > @max_proxy_depth do
    JSThrow.range_error!("Maximum call stack size exceeded")
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array({:qb_arr, _}, _), do: true
  defp is_array(list, _) when is_list(list), do: true

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array({:obj, ref}, depth) do
    cond do
      Heap.get_array_prop(ref, "__arguments__") == true ->
        false

      Heap.get_array_proto() == {:obj, ref} ->
        true

      true ->
        case Heap.get_obj(ref) do
          {:qb_arr, _} ->
            true

          list when is_list(list) ->
            true

          %{"__proxy_revoked__" => true} ->
            JSThrow.type_error!("Cannot perform operation on a revoked proxy")

          %{proxy_target() => target} ->
            is_array(target, depth + 1)

          _ ->
            false
        end
    end
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array(_, _), do: false

  static "from" do
    from(args, this)
  end

  static "of" do
    of(args, this)
  end

  static "fromAsync" do
    PromiseState.resolved(from(args, this))
  end

  defp of(args, {:builtin, "Array", _}), do: Heap.wrap(args)
  defp of(args, nil), do: Heap.wrap(args)
  defp of(args, :undefined), do: Heap.wrap(args)

  defp of(args, constructor) do
    if constructable_from?(constructor) do
      target = QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, [length(args)])

      Enum.each(Enum.with_index(args), fn {value, index} ->
        create_data_property_or_throw(target, Integer.to_string(index), value)
      end)

      Put.put(target, "length", length(args))
      target
    else
      Heap.wrap(args)
    end
  end

  # ── Mutation helpers ──

  defp push(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp push(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp push(value, _args) when is_binary(value),
    do: JSThrow.type_error!("Cannot assign to read only property")

  defp push(value, args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    new_len = len + length(args)

    if new_len > @max_safe_integer do
      JSThrow.type_error!("Invalid array length")
    end

    Enum.each(Enum.with_index(args, len), fn {item, index} ->
      put_or_throw(receiver, Integer.to_string(index), item)
    end)

    put_length_or_throw(receiver, new_len)
    new_len
  end

  defp pop(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp pop(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp pop(value, _args) when is_binary(value),
    do: JSThrow.type_error!("Cannot assign to read only property")

  defp pop(value, _args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)

    if len == 0 do
      put_length_or_throw(receiver, 0)
      :undefined
    else
      index = len - 1
      key = Integer.to_string(index)

      element = get_array_hole_aware(receiver, key)

      unless Delete.delete_property(receiver, key) do
        JSThrow.type_error!("Cannot delete property")
      end

      put_length_or_throw(receiver, index)
      element
    end
  end

  defp get_array_hole_aware({:obj, ref} = receiver, key) do
    case Heap.get_obj(ref) do
      data when is_list(data) ->
        if array_own_value_present?(ref, key) do
          Get.get(receiver, key)
        else
          get_array_inherited_value(ref, key)
        end

      {:qb_arr, _} ->
        if array_own_value_present?(ref, key) do
          Get.get(receiver, key)
        else
          get_array_inherited_value(ref, key)
        end

      _ ->
        Get.get(receiver, key)
    end
  end

  defp get_array_hole_aware(receiver, key), do: Get.get(receiver, key)

  defp array_own_value_present?(ref, key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 ->
        Heap.array_get(ref, idx) != :undefined or Heap.get_prop_desc(ref, key) != nil or
          Heap.get_array_prop(ref, key) != :undefined

      _ ->
        Heap.get_prop_desc(ref, key) != nil or Heap.get_array_prop(ref, key) != :undefined
    end
  end

  defp get_array_inherited_value(ref, key) do
    array_proto = Heap.get_array_proto(ref)
    object_proto = Heap.get_object_prototype()

    cond do
      match?({:obj, _}, array_proto) and HasProperty.has_property?(array_proto, key) ->
        Get.get(array_proto, key)

      match?({:obj, _}, object_proto) and HasProperty.has_property?(object_proto, key) ->
        Get.get(object_proto, key)

      true ->
        :undefined
    end
  end

  defp put_length_or_throw({:obj, ref} = receiver, length) do
    case {Heap.get_prop_desc(ref, "length"), Heap.get_obj_raw(ref)} do
      {%{writable: false}, _} ->
        JSThrow.type_error!("Cannot assign to read only property")

      {_, %{"length" => {:accessor, _getter, nil}}} ->
        JSThrow.type_error!("Cannot assign to read only property")

      _ ->
        Put.put(receiver, "length", length)
    end
  end

  defp put_length_or_throw(receiver, length) do
    case OwnProperty.descriptor(receiver, "length") do
      {:obj, desc_ref} ->
        if Get.get({:obj, desc_ref}, "writable") == false do
          JSThrow.type_error!("Cannot assign to read only property")
        end

      _ ->
        :ok
    end

    Put.put(receiver, "length", length)
  end

  defp put_or_throw({:obj, ref} = receiver, key, value) do
    case {Heap.get_prop_desc(ref, key), Heap.get_obj_raw(ref)} do
      {%{writable: false}, _} ->
        JSThrow.type_error!("Cannot assign to read only property")

      {_, %{^key => {:accessor, _getter, nil}}} ->
        JSThrow.type_error!("Cannot assign to read only property")

      _ ->
        Put.put(receiver, key, value)
    end
  end

  defp put_or_throw(receiver, key, value), do: Put.put(receiver, key, value)

  defp shift(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp shift(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp shift(value, _args) when is_binary(value),
    do: JSThrow.type_error!("Cannot assign to read only property")

  defp shift(value, _args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)

    if len == 0 do
      put_length_or_throw(receiver, 0)
      :undefined
    else
      first = get_array_hole_aware(receiver, "0")

      if len > 1 do
        1..(len - 1)
        |> Enum.each(fn from ->
          from_key = Integer.to_string(from)
          to_key = Integer.to_string(from - 1)

          if HasProperty.has_property?(receiver, from_key) do
            Put.put(receiver, to_key, Get.get(receiver, from_key))
          else
            delete_or_throw(receiver, to_key)
          end
        end)
      end

      delete_or_throw(receiver, Integer.to_string(len - 1))
      put_length_or_throw(receiver, len - 1)
      first
    end
  end

  defp unshift(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp unshift(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp unshift(value, _args) when is_binary(value),
    do: JSThrow.type_error!("Cannot assign to read only property")

  defp unshift(value, args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    arg_count = length(args)
    new_len = len + arg_count

    if new_len > @max_safe_integer do
      JSThrow.type_error!("Invalid array length")
    end

    if arg_count > 0 and len > 0 do
      (len - 1)..0//-1
      |> Enum.each(fn from ->
        from_key = Integer.to_string(from)
        to_key = Integer.to_string(from + arg_count)

        if HasProperty.has_property?(receiver, from_key) do
          put_or_throw(receiver, to_key, Get.get(receiver, from_key))
        else
          delete_or_throw(receiver, to_key)
        end
      end)
    end

    args
    |> Enum.with_index()
    |> Enum.each(fn {item, index} -> put_or_throw(receiver, Integer.to_string(index), item) end)

    put_length_or_throw(receiver, new_len)
    new_len
  end

  # ── Higher-order ──

  defp map(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp map(:undefined, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp map({:qb_arr, arr}, args), do: map(:array.to_list(arr), args)
  defp map(value, args), do: map_array_like(find_receiver(value), args)

  defp map_array_like(this, [fun | rest]) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = filter_this_arg(rest)
    target = map_target(this, len)

    if len > 0 do
      Enum.each(0..(len - 1), fn idx ->
        key = Integer.to_string(idx)

        if HasProperty.has_property?(this, key) do
          value = find_value_at(this, idx)

          mapped =
            QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [value, idx, this], this_arg)

          create_data_property_or_throw(target, key, mapped)
        end
      end)
    end

    Put.put(target, "length", len)
    target
  end

  defp map_array_like(this, _args) do
    _len = array_like_length(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp map_target(_receiver, len) when len > @max_array_length do
    JSThrow.range_error!("Invalid array length")
  end

  defp map_target(receiver, len) do
    case concat_species_constructor(receiver) do
      :array ->
        Heap.wrap(List.duplicate(:undefined, min(len, 100_000)))

      constructor ->
        ensure_object_result(
          QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, [len])
        )
    end
  end

  defp filter(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp filter(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp filter({:obj, _} = obj, args), do: filter_array_like(obj, args)

  defp filter(value, args) when is_boolean(value) or is_number(value) or is_binary(value) do
    value
    |> primitive_object()
    |> filter_array_like(args)
  end

  defp filter({:builtin, _, _} = obj, args), do: filter_array_like(obj, args)
  defp filter({:regexp, _, _, _} = obj, args), do: filter_array_like(obj, args)
  defp filter({:regexp, _, _} = obj, args), do: filter_array_like(obj, args)

  defp filter({:qb_arr, arr}, args), do: filter(:array.to_list(arr), args)

  defp filter(list, [fun | rest]) when is_list(list) do
    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = filter_this_arg(rest)

    list
    |> Enum.with_index()
    |> Enum.filter(fn {val, idx} ->
      Runtime.truthy?(
        QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [val, idx, list], this_arg)
      )
    end)
    |> Enum.map(fn {val, _} -> val end)
  end

  defp filter(callable, args) do
    if QuickBEAM.VM.Builtin.callable?(callable) do
      filter_array_like(callable, args)
    else
      filter_non_callable(callable, args)
    end
  end

  defp filter_non_callable(_, _), do: JSThrow.type_error!("callbackfn is not a function")

  defp filter_array_like(this, [fun | rest]) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = filter_this_arg(rest)

    result =
      if len == 0 do
        []
      else
        0..(len - 1)
        |> Enum.reduce([], fn idx, acc ->
          key = Integer.to_string(idx)

          if HasProperty.has_property?(this, key) do
            value = Get.get(this, key)

            if Runtime.truthy?(
                 QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [value, idx, this], this_arg)
               ) do
              [value | acc]
            else
              acc
            end
          else
            acc
          end
        end)
        |> Enum.reverse()
      end

    wrap_filter_result(this, result)
  end

  defp filter_array_like(this, _args) do
    _len = array_like_length(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp filter_this_arg([value | _]), do: value
  defp filter_this_arg(_), do: :undefined

  defp wrap_filter_result(receiver, result) do
    target = filter_target(receiver)

    result
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      create_data_property_or_throw(target, Integer.to_string(index), value)
    end)

    Put.put(target, "length", length(result))
    target
  end

  defp populate_flat_result(target, result) do
    result
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      create_data_property_or_throw(target, Integer.to_string(index), value)
    end)

    target
  end

  defp filter_target(receiver) do
    case concat_species_constructor(receiver) do
      :array ->
        Heap.wrap([])

      constructor ->
        ensure_object_result(
          QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, [0])
        )
    end
  end

  defp ensure_object_result({:obj, _} = obj), do: obj
  defp ensure_object_result(%QuickBEAM.VM.Function{} = fun), do: fun
  defp ensure_object_result({:closure, _, %QuickBEAM.VM.Function{}} = closure), do: closure
  defp ensure_object_result({:builtin, _, _} = builtin), do: builtin

  defp ensure_object_result(_),
    do: JSThrow.type_error!("Species constructor did not return an object")

  defp reduce(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp reduce(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp reduce(value, args), do: reduce_array_like(find_receiver(value), args, :forward)

  defp reduce_right(nil, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp reduce_right(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp reduce_right(value, args), do: reduce_array_like(find_receiver(value), args, :reverse)

  defp reduce_array_like(this, [fun | rest], direction) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    indexes = reduce_indexes(this, len, direction)

    {acc, remaining_indexes} =
      case rest do
        [initial | _] ->
          {initial, indexes}

        _ ->
          find_initial_accumulator(this, indexes)
      end

    Enum.reduce(remaining_indexes, acc, fn idx, current_acc ->
      key = Integer.to_string(idx)

      if HasProperty.has_property?(this, key) do
        value = find_value_at(this, idx)

        QuickBEAM.VM.Invocation.invoke_with_receiver(
          fun,
          [current_acc, value, idx, this],
          :undefined
        )
      else
        current_acc
      end
    end)
  end

  defp reduce_array_like(this, _args, _direction) do
    _len = array_like_length(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp reduce_indexes(_this, 0, _direction), do: []

  defp reduce_indexes(this, len, direction) when len > 100_000 do
    this
    |> OwnProperty.descriptor_keys()
    |> Enum.flat_map(&array_property_index/1)
    |> Enum.filter(&(&1 >= 0 and &1 < len))
    |> Enum.uniq()
    |> sort_reduce_indexes(direction)
  end

  defp reduce_indexes(_this, len, :forward), do: Enum.to_list(0..(len - 1))
  defp reduce_indexes(_this, len, :reverse), do: Enum.to_list((len - 1)..0//-1)

  defp sort_reduce_indexes(indexes, :forward), do: Enum.sort(indexes)
  defp sort_reduce_indexes(indexes, :reverse), do: Enum.sort(indexes, :desc)

  defp array_property_index(key) when is_integer(key) and key >= 0, do: [key]

  defp array_property_index(key) when is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> [idx]
      _ -> []
    end
  end

  defp array_property_index(_key), do: []

  defp find_initial_accumulator(this, indexes) do
    case Enum.split_while(indexes, fn idx ->
           not HasProperty.has_property?(this, Integer.to_string(idx))
         end) do
      {_skipped, [idx | rest]} -> {find_value_at(this, idx), rest}
      {_skipped, []} -> JSThrow.type_error!("Reduce of empty array with no initial value")
    end
  end

  defp for_each(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp for_each(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp for_each({:qb_arr, arr}, args), do: for_each(:array.to_list(arr), args)
  defp for_each(value, args), do: for_each_array_like(find_receiver(value), args)

  defp for_each_array_like(this, [fun | rest]) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callback must be callable")
    end

    this_arg = filter_this_arg(rest)

    if len > 0 do
      Enum.each(0..(len - 1), fn idx ->
        key = Integer.to_string(idx)

        if HasProperty.has_property?(this, key) do
          value = find_value_at(this, idx)
          QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [value, idx, this], this_arg)
        end
      end)
    end

    :undefined
  end

  defp for_each_array_like(this, _args) do
    _len = array_like_length(this)
    JSThrow.type_error!("callback must be callable")
  end

  # ── Search ──

  defp index_of(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp index_of(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp index_of({:qb_arr, arr}, args), do: index_of(:array.to_list(arr), args)
  defp index_of(value, args), do: index_of_array_like(find_receiver(value), args)

  defp index_of_array_like(list, [search_element | rest]) when is_list(list) do
    len = length(list)

    case search_start(rest, len) do
      :past_end ->
        -1

      start ->
        list
        |> Enum.with_index()
        |> Enum.drop(start)
        |> Enum.find_value(-1, fn {value, idx} ->
          if strict_equal_for_index?(value, search_element), do: idx
        end)
    end
  end

  defp index_of_array_like(this, [search_element | rest]) do
    len = array_like_length(this)

    case search_start(rest, len) do
      :past_end ->
        -1

      start ->
        find_index_in_range(start, len, fn idx ->
          key = Integer.to_string(idx)

          HasProperty.has_property?(this, key) and
            strict_equal_for_index?(find_value_at(this, idx), search_element)
        end)
    end
  end

  defp index_of_array_like(this, []), do: index_of_array_like(this, [:undefined])
  defp index_of_array_like(_this, _args), do: -1

  defp strict_equal_for_index?(left, right) do
    not (nan_number?(left) or nan_number?(right)) and
      (Runtime.strict_equal?(left, right) or
         (is_number(left) and is_number(right) and left == right))
  end

  defp find_index_in_range(start, len, predicate) when start < len do
    Enum.find_value(start..(len - 1), -1, fn idx ->
      if predicate.(idx), do: idx
    end)
  end

  defp find_index_in_range(_start, _len, _predicate), do: -1

  defp last_index_of(nil, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp last_index_of(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp last_index_of({:qb_arr, arr}, args), do: last_index_of(:array.to_list(arr), args)
  defp last_index_of(value, args), do: last_index_of_array_like(find_receiver(value), args)

  defp last_index_of_array_like(list, [search_element | rest]) when is_list(list) do
    len = length(list)

    case last_search_start(rest, len) do
      :before_start ->
        -1

      start ->
        list
        |> Enum.with_index()
        |> Enum.take(start + 1)
        |> Enum.reverse()
        |> Enum.find_value(-1, fn {value, idx} ->
          if strict_equal_for_index?(value, search_element), do: idx
        end)
    end
  end

  defp last_index_of_array_like(this, [search_element | rest]) do
    len = array_like_length(this)

    case last_search_start(rest, len) do
      :before_start ->
        -1

      start ->
        this
        |> last_index_of_indexes(len, start)
        |> Enum.find_value(-1, fn idx ->
          key = Integer.to_string(idx)

          if HasProperty.has_property?(this, key) and
               strict_equal_for_index?(find_value_at(this, idx), search_element) do
            idx
          end
        end)
    end
  end

  defp last_index_of_array_like(this, []), do: last_index_of_array_like(this, [:undefined])
  defp last_index_of_array_like(_this, _args), do: -1

  defp last_index_of_indexes(this, len, start) when len > 100_000 do
    this
    |> OwnProperty.descriptor_keys()
    |> Enum.flat_map(&array_property_index/1)
    |> Enum.filter(&(&1 >= 0 and &1 <= start and &1 < len))
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  defp last_index_of_indexes(_this, _len, start), do: start..0//-1

  defp last_search_start(_rest, 0), do: :before_start

  defp last_search_start([value | _], len),
    do: last_search_start_from(to_integer_or_infinity(value), len)

  defp last_search_start(_rest, len), do: len - 1

  defp last_search_start_from(:infinity, len), do: len - 1
  defp last_search_start_from(:neg_infinity, _len), do: :before_start
  defp last_search_start_from(value, len) when value >= 0, do: min(value, len - 1)

  defp last_search_start_from(value, len),
    do: if(len + value < 0, do: :before_start, else: len + value)

  defp includes(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp includes(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp includes({:qb_arr, arr}, args), do: includes(:array.to_list(arr), args)
  defp includes(value, args), do: includes_array_like(find_receiver(value), args)

  defp includes_array_like(this, [search_element | rest]) do
    len = array_like_length(this)

    case search_start(rest, len) do
      :past_end ->
        false

      start ->
        find_index_in_range(start, len, fn idx ->
          same_value_zero?(find_value_at(this, idx), search_element)
        end) != -1
    end
  end

  defp includes_array_like(this, []), do: includes_array_like(this, [:undefined])
  defp includes_array_like(_this, _args), do: false

  defp search_start(_rest, 0), do: :past_end
  defp search_start([value | _], len), do: search_start_from(to_integer_or_infinity(value), len)
  defp search_start(_rest, _len), do: 0

  defp search_start_from(:infinity, _len), do: :past_end
  defp search_start_from(:neg_infinity, _len), do: 0
  defp search_start_from(value, len) when value >= 0 and value < len, do: value
  defp search_start_from(value, len) when value >= len, do: :past_end
  defp search_start_from(value, len), do: max(len + value, 0)

  defp same_value_zero?(left, right) do
    Runtime.strict_equal?(left, right) or (is_number(left) and is_number(right) and left == right) or
      (nan_number?(left) and nan_number?(right))
  end

  defp nan_number?(value) when is_float(value) do
    <<bits::64>> = <<value::float-64>>
    exponent = Bitwise.band(Bitwise.bsr(bits, 52), 0x7FF)
    mantissa = Bitwise.band(bits, 0xFFFFFFFFFFFFF)
    exponent == 0x7FF and mantissa != 0
  end

  defp nan_number?(:nan), do: true
  defp nan_number?(_), do: false

  # ── Slice / splice ──

  defp slice(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp slice(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp slice(value, args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    start_idx = slice_start(args, len)
    end_idx = slice_end(args, len)
    count = max(end_idx - start_idx, 0)
    target = slice_target(receiver, count)

    if count > 0 do
      0..(count - 1)
      |> Enum.each(fn offset ->
        from = start_idx + offset
        key = Integer.to_string(from)

        if HasProperty.has_property?(receiver, key) do
          create_data_property_or_throw(
            target,
            Integer.to_string(offset),
            find_value_at(receiver, from)
          )
        end
      end)
    end

    Put.put(target, "length", count)
    target
  end

  defp slice_target(receiver, count) do
    case concat_species_constructor(receiver) do
      :array ->
        if count > @max_array_length do
          JSThrow.range_error!("Invalid array length")
        end

        Heap.wrap([])

      constructor ->
        ensure_object_result(
          QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, [count])
        )
    end
  end

  defp slice_start(args, len) do
    args |> Enum.at(0, 0) |> to_integer_or_infinity() |> slice_relative_index(len)
  end

  defp slice_end(args, len) do
    case Enum.fetch(args, 1) do
      {:ok, value} when value not in [nil, :undefined] ->
        value |> to_integer_or_infinity() |> slice_relative_index(len)

      _ ->
        len
    end
  end

  defp slice_relative_index(:neg_infinity, _len), do: 0
  defp slice_relative_index(:infinity, len), do: len
  defp slice_relative_index(index, len) when index < 0, do: max(len + index, 0)
  defp slice_relative_index(index, len), do: min(index, len)

  defp splice(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp splice(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp splice(value, args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    actual_start = splice_start(args, len)
    actual_delete_count = splice_delete_count(args, len, actual_start)
    insert = Enum.drop(args, 2)
    insert_count = length(insert)
    new_len = len - actual_delete_count + insert_count

    if new_len > @max_safe_integer do
      JSThrow.type_error!("Invalid array length")
    end

    removed = splice_removed_target(receiver, actual_delete_count)
    copy_splice_removed(receiver, removed, actual_start, actual_delete_count)
    set_splice_removed_length(removed, actual_delete_count)

    cond do
      insert_count < actual_delete_count ->
        shift_splice_left(receiver, actual_start, len, actual_delete_count, insert_count)

      insert_count > actual_delete_count ->
        shift_splice_right(receiver, actual_start, len, actual_delete_count, insert_count)

      true ->
        :ok
    end

    insert
    |> Enum.with_index(actual_start)
    |> Enum.each(fn {item, index} -> Put.put(receiver, Integer.to_string(index), item) end)

    put_length_or_throw(receiver, new_len)
    removed
  end

  defp set_splice_removed_length({:obj, ref} = removed, length) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, proxy_handler() => _handler} ->
        Put.set(removed, "length", length, removed)

      _ ->
        Put.put(removed, "length", length)
    end
  end

  defp set_splice_removed_length(removed, length), do: Put.put(removed, "length", length)

  defp splice_start([], _len), do: 0

  defp splice_start([start | _], len) do
    start |> to_integer_or_infinity() |> slice_relative_index(len)
  end

  defp splice_delete_count(args, len, actual_start) do
    case args do
      [] ->
        0

      [_start] ->
        len - actual_start

      [_start, delete_count | _] ->
        delete_count |> to_integer_or_infinity() |> clamp_splice_delete(len - actual_start)
    end
  end

  defp clamp_splice_delete(:neg_infinity, _max), do: 0
  defp clamp_splice_delete(:infinity, max_delete), do: max_delete
  defp clamp_splice_delete(value, max_delete), do: value |> max(0) |> min(max_delete)

  defp splice_removed_target(receiver, count), do: slice_target(receiver, count)

  defp copy_splice_removed(_receiver, _removed, _actual_start, 0), do: :ok

  defp copy_splice_removed(receiver, removed, actual_start, actual_delete_count) do
    0..(actual_delete_count - 1)
    |> Enum.each(fn index ->
      from = actual_start + index
      from_key = Integer.to_string(from)

      if HasProperty.has_property?(receiver, from_key) do
        create_data_property_or_throw(
          removed,
          Integer.to_string(index),
          find_value_at(receiver, from)
        )
      end
    end)
  end

  defp shift_splice_left(receiver, actual_start, len, actual_delete_count, insert_count) do
    last_moved = len - actual_delete_count - 1

    if actual_start <= last_moved do
      actual_start..last_moved
      |> Enum.each(fn from ->
        from_key = Integer.to_string(from + actual_delete_count)
        to_key = Integer.to_string(from + insert_count)

        if HasProperty.has_property?(receiver, from_key) do
          Put.put(receiver, to_key, Get.get(receiver, from_key))
        else
          delete_or_throw(receiver, to_key)
        end
      end)
    end

    delete_start = len - actual_delete_count + insert_count

    if delete_start < len do
      delete_start..(len - 1)
      |> Enum.each(fn index -> delete_or_throw(receiver, Integer.to_string(index)) end)
    end
  end

  defp shift_splice_right(receiver, actual_start, len, actual_delete_count, insert_count) do
    last_moved = len - actual_delete_count - 1

    if actual_start <= last_moved do
      last_moved..actual_start//-1
      |> Enum.each(fn from ->
        from_key = Integer.to_string(from + actual_delete_count)
        to_key = Integer.to_string(from + insert_count)

        if HasProperty.has_property?(receiver, from_key) do
          Put.put(receiver, to_key, Get.get(receiver, from_key))
        else
          delete_or_throw(receiver, to_key)
        end
      end)
    end
  end

  # ── Transform ──

  defp join(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp join(:undefined, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp join({:qb_arr, arr}, args), do: join(:array.to_list(arr), args)

  defp join(value, args) do
    this = find_receiver(value)
    len = array_like_length(this)
    separator = join_separator(args)

    if len == 0 do
      ""
    else
      0..(len - 1)
      |> Enum.map_join(separator, fn idx ->
        this
        |> find_value_at(idx)
        |> array_element_to_string()
      end)
    end
  end

  defp array_to_string(nil), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp array_to_string(:undefined),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp array_to_string(value) do
    receiver = find_receiver(value)
    join_fn = Get.get(receiver, "join")

    if QuickBEAM.VM.Builtin.callable?(join_fn) do
      QuickBEAM.VM.Invocation.invoke_with_receiver(join_fn, [], receiver)
    else
      array_object_tag_string(receiver)
    end
  end

  defp array_object_tag_string({:obj, ref} = obj) do
    custom_tag = Get.get(obj, {:symbol, "Symbol.toStringTag"})

    tag =
      if is_binary(custom_tag) do
        custom_tag
      else
        case Heap.get_obj(ref, %{}) do
          list when is_list(list) ->
            if Heap.get_array_prop(ref, "__arguments__") == true, do: "Arguments", else: "Array"

          {:qb_arr, _} ->
            if Heap.get_array_prop(ref, "__arguments__") == true, do: "Arguments", else: "Array"

          map when is_map(map) ->
            cond do
              Map.has_key?(map, proxy_target()) and is_array(Map.get(map, proxy_target())) ->
                "Array"

              Map.has_key?(map, proxy_target()) and
                  QuickBEAM.VM.Builtin.callable?(Map.get(map, proxy_target())) ->
                "Function"

              QuickBEAM.VM.ObjectModel.WrappedPrimitive.tag(map) != nil ->
                QuickBEAM.VM.ObjectModel.WrappedPrimitive.tag(map)

              Map.has_key?(map, date_ms()) ->
                "Date"

              Map.has_key?(map, "__error_name__") ->
                "Error"

              true ->
                "Object"
            end

          _ ->
            "Object"
        end
      end

    "[object #{tag}]"
  end

  defp array_object_tag_string(value) when is_boolean(value), do: "[object Boolean]"
  defp array_object_tag_string(value) when is_number(value), do: "[object Number]"
  defp array_object_tag_string(value) when is_binary(value), do: "[object String]"
  defp array_object_tag_string({:symbol, _}), do: "[object Symbol]"
  defp array_object_tag_string({:symbol, _, _}), do: "[object Symbol]"

  defp array_object_tag_string({:regexp, _, _} = regexp),
    do: tagged_object_string(regexp, "RegExp")

  defp array_object_tag_string({:regexp, _, _, _} = regexp),
    do: tagged_object_string(regexp, "RegExp")

  defp array_object_tag_string(%QuickBEAM.VM.Function{}), do: "[object Function]"

  defp array_object_tag_string({tag, _, %QuickBEAM.VM.Function{}})
       when tag in [:closure, :bound],
       do: "[object Function]"

  defp array_object_tag_string({:bound, _, _, _, _}), do: "[object Function]"

  defp array_object_tag_string({:builtin, name, map} = obj) when is_map(map) do
    custom_tag = Get.get(obj, {:symbol, "Symbol.toStringTag"})
    "[object #{if is_binary(custom_tag), do: custom_tag, else: name}]"
  end

  defp array_object_tag_string({:builtin, _, _}), do: "[object Function]"
  defp array_object_tag_string(_), do: "[object Object]"

  defp tagged_object_string(obj, fallback_tag) do
    custom_tag = Get.get(obj, {:symbol, "Symbol.toStringTag"})
    "[object #{if is_binary(custom_tag), do: custom_tag, else: fallback_tag}]"
  end

  defp to_locale_string(nil),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_locale_string(:undefined),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_locale_string(value) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)

    if len == 0 do
      ""
    else
      0..(len - 1)
      |> Enum.map_join(",", fn index ->
        receiver
        |> find_value_at(index)
        |> array_element_to_locale_string()
      end)
    end
  end

  defp array_element_to_locale_string(value) when value in [nil, :undefined], do: ""

  defp array_element_to_locale_string(value) do
    locale_string_fn = Get.get(value, "toLocaleString")

    unless QuickBEAM.VM.Builtin.callable?(locale_string_fn) do
      JSThrow.type_error!("toLocaleString is not callable")
    end

    value
    |> then(&QuickBEAM.VM.Invocation.invoke_with_receiver(locale_string_fn, [], &1))
    |> Runtime.stringify()
  end

  defp join_separator([:undefined | _]), do: ","
  defp join_separator([]), do: ","
  defp join_separator([sep | _]), do: Runtime.stringify(sep)

  defp array_element_to_string(:undefined), do: ""
  defp array_element_to_string(nil), do: ""
  defp array_element_to_string(val), do: Runtime.stringify(val)

  defp concat(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp concat(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp concat(this, args) do
    receiver = concat_receiver(this)
    target = concat_target(receiver)

    values =
      [receiver | args]
      |> Enum.reduce([], &concat_item/2)

    concat_result(target, values)
  end

  defp concat_receiver({:obj, _} = obj), do: obj
  defp concat_receiver({:qb_arr, _} = arr), do: arr
  defp concat_receiver(list) when is_list(list), do: list
  defp concat_receiver(value), do: QuickBEAM.VM.Runtime.Globals.Constructors.object([value], nil)

  defp concat_target(receiver) do
    case concat_species_constructor(receiver) do
      :array -> Heap.wrap([])
      constructor -> QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, [0])
    end
  end

  defp concat_result(target, entries) do
    Enum.each(Enum.with_index(entries), fn
      {{:present, value}, index} ->
        create_data_property_or_throw(target, Integer.to_string(index), value)

      {:hole, _index} ->
        :ok
    end)

    Put.put(target, "length", length(entries))
    target
  end

  defp concat_species_constructor(receiver) do
    if is_array(receiver) do
      constructor = Get.get(receiver, "constructor")
      concat_species_from_constructor(constructor)
    else
      :array
    end
  end

  defp concat_species_from_constructor({:builtin, "Array", _}), do: :array
  defp concat_species_from_constructor(:undefined), do: :array

  defp concat_species_from_constructor({:obj, _} = constructor) do
    concat_species_from_constructor_object(constructor)
  end

  defp concat_species_from_constructor(constructor) do
    if constructable_from?(constructor) do
      concat_species_from_constructor_object(constructor)
    else
      JSThrow.type_error!("object.constructor is not a constructor")
    end
  end

  defp concat_species_from_constructor_object(constructor) do
    species = Get.get(constructor, {:symbol, "Symbol.species"})

    cond do
      species in [nil, :undefined] -> :array
      constructable_from?(species) -> species
      true -> JSThrow.type_error!("object.constructor[Symbol.species] is not a constructor")
    end
  end

  defp concat_item(value, acc) do
    if concat_spreadable?(value) do
      acc ++ concat_spread_values(value, length(acc))
    else
      acc ++ [{:present, value}]
    end
  end

  defp concat_spreadable?(value) do
    spreadable = concat_spreadable_flag(value)

    if spreadable != :undefined do
      Runtime.truthy?(spreadable)
    else
      is_array(value)
    end
  end

  defp concat_spreadable_flag(value) do
    sym = {:symbol, "Symbol.isConcatSpreadable"}

    case Get.get(value, sym) do
      :undefined -> inherited_concat_spreadable_flag(value, sym)
      other -> other
    end
  end

  defp inherited_concat_spreadable_flag(value, sym) do
    if QuickBEAM.VM.Builtin.callable?(value) do
      case Heap.get_func_proto() do
        {:obj, _} = proto -> Get.get(proto, sym)
        _ -> :undefined
      end
    else
      :undefined
    end
  end

  defp concat_spread_values(value, current_length) do
    len = concat_length(value)

    if current_length + len > @max_safe_integer do
      JSThrow.type_error!("Invalid array length")
    end

    if len == 0 do
      []
    else
      for index <- 0..(len - 1) do
        key = Integer.to_string(index)

        if HasProperty.has_property?(value, key) do
          {:present, Get.get(value, key)}
        else
          :hole
        end
      end
    end
  end

  defp concat_length({:qb_arr, arr}), do: :array.size(arr)
  defp concat_length(list) when is_list(list), do: length(list)
  defp concat_length(value), do: max(Runtime.to_int(Get.get(value, "length")), 0)

  defp reverse(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp reverse(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp reverse(value, _args) when is_binary(value),
    do: JSThrow.type_error!("Cannot assign to read only property")

  defp reverse(value, _args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)

    if len > 1 do
      reverse_pairs(receiver, 0, len - 1)
    end

    receiver
  end

  defp reverse_pairs(_receiver, lower, upper) when lower >= upper, do: :ok

  defp reverse_pairs(receiver, lower, upper) do
    lower_key = Integer.to_string(lower)
    upper_key = Integer.to_string(upper)
    lower_exists = HasProperty.has_property?(receiver, lower_key)
    lower_value = if lower_exists, do: Get.get(receiver, lower_key), else: :undefined
    upper_exists = HasProperty.has_property?(receiver, upper_key)
    upper_value = if upper_exists, do: Get.get(receiver, upper_key), else: :undefined

    cond do
      lower_exists and upper_exists ->
        reverse_put(receiver, lower, lower_key, upper_value)
        reverse_put(receiver, upper, upper_key, lower_value)

      upper_exists ->
        reverse_put(receiver, lower, lower_key, upper_value)
        delete_or_throw(receiver, upper_key)

      lower_exists ->
        delete_or_throw(receiver, lower_key)
        reverse_put(receiver, upper, upper_key, lower_value)

      true ->
        :ok
    end

    reverse_pairs(receiver, lower + 1, upper - 1)
  end

  defp reverse_put({:obj, ref} = receiver, index, _key, value) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        Put.put_element(receiver, index, value)

      %{proxy_target() => _target, proxy_handler() => _handler} ->
        Put.set(receiver, Integer.to_string(index), value, receiver)

      _ ->
        Put.put(receiver, Integer.to_string(index), value)
    end
  end

  defp reverse_put(receiver, _index, key, value), do: Put.put(receiver, key, value)

  defp delete_or_throw(receiver, key) do
    unless Delete.delete_property(receiver, key) do
      JSThrow.type_error!("Cannot delete property")
    end
  end

  defp sort(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp sort(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp sort(value, args) do
    compare_fn = sort_compare_fn(args)
    receiver = find_receiver(value)
    len = array_like_length(receiver)

    values =
      if len == 0 do
        []
      else
        0..(len - 1)
        |> Enum.reduce([], fn index, acc ->
          key = Integer.to_string(index)

          if index < array_like_length(receiver) and HasProperty.has_property?(receiver, key) do
            [{find_value_at(receiver, index), index} | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()
      end

    sorted = sort_values(values, compare_fn)

    sorted
    |> Enum.with_index()
    |> Enum.each(fn {{value, _original_index}, index} ->
      Put.put_element(receiver, index, value)
    end)

    sorted_count = length(sorted)

    if sorted_count < len do
      sorted_count..(len - 1)
      |> Enum.each(fn index -> delete_or_throw(receiver, Integer.to_string(index)) end)
    end

    receiver
  end

  defp sort_compare_fn([]), do: :default
  defp sort_compare_fn([:undefined | _]), do: :default

  defp sort_compare_fn([fun | _]) do
    if QuickBEAM.VM.Builtin.callable?(fun) do
      fun
    else
      JSThrow.type_error!("The comparison function must be either a function or undefined")
    end
  end

  defp sort_values(values, :default), do: Enum.sort(values, &default_sort_before?/2)

  defp sort_values(values, compare_fn),
    do: Enum.sort(values, &custom_sort_before?(&1, &2, compare_fn))

  defp default_sort_before?({left, left_index}, {right, right_index}) do
    compare_default_sort(left, right, left_index, right_index) < 0
  end

  defp custom_sort_before?({left, left_index}, {right, right_index}, compare_fn) do
    compare_custom_sort(left, right, left_index, right_index, compare_fn) < 0
  end

  defp compare_default_sort(:undefined, :undefined, left_index, right_index),
    do: left_index - right_index

  defp compare_default_sort(:undefined, _right, _left_index, _right_index), do: 1
  defp compare_default_sort(_left, :undefined, _left_index, _right_index), do: -1

  defp compare_default_sort(left, right, left_index, right_index) do
    left_string = Runtime.stringify(left)
    right_string = Runtime.stringify(right)

    cond do
      left_string < right_string -> -1
      left_string > right_string -> 1
      true -> left_index - right_index
    end
  end

  defp compare_custom_sort(:undefined, :undefined, left_index, right_index, _compare_fn),
    do: left_index - right_index

  defp compare_custom_sort(:undefined, _right, _left_index, _right_index, _compare_fn), do: 1
  defp compare_custom_sort(_left, :undefined, _left_index, _right_index, _compare_fn), do: -1

  defp compare_custom_sort(left, right, left_index, right_index, compare_fn) do
    case QuickBEAM.VM.Invocation.invoke_with_receiver(compare_fn, [left, right], :undefined) do
      value when is_number(value) and value < 0 -> -1
      value when is_number(value) and value > 0 -> 1
      _ -> left_index - right_index
    end
  end

  defp flat(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp flat(:undefined, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp flat({:obj, ref} = obj, args) do
    depth = flat_depth(args)

    {target, result} =
      case Heap.get_obj(ref) do
        {:qb_arr, arr} ->
          {filter_target(obj), flatten_array(:array.to_list(arr), depth)}

        list when is_list(list) ->
          {filter_target(obj), flatten_array(list, depth)}

        _ ->
          len = array_like_length(obj)
          {filter_target(obj), flat_array_like(obj, depth, len)}
      end

    populate_flat_result(target, result)
  end

  defp flat({:qb_arr, arr}, args),
    do: Heap.wrap(flatten_array(:array.to_list(arr), flat_depth(args)))

  defp flat(list, args) when is_list(list), do: Heap.wrap(flatten_array(list, flat_depth(args)))
  defp flat(_, _), do: []

  defp flat_depth([]), do: 1
  defp flat_depth([:undefined | _]), do: 1
  defp flat_depth([value | _]), do: normalize_flat_depth(to_integer_or_infinity(value))
  defp flat_depth(_), do: 1

  defp normalize_flat_depth(:infinity), do: :infinity
  defp normalize_flat_depth(:neg_infinity), do: 0
  defp normalize_flat_depth(value) when value < 0, do: 0
  defp normalize_flat_depth(value), do: value

  defp flat_array_like(obj, depth), do: flat_array_like(obj, depth, array_like_length(obj))

  defp flat_array_like(obj, depth, len) do
    if len == 0 do
      []
    else
      0..(len - 1)
      |> Enum.flat_map(fn idx ->
        key = Integer.to_string(idx)

        if HasProperty.has_property?(obj, key) do
          obj |> Get.get(key) |> flat_item(depth)
        else
          []
        end
      end)
    end
  end

  defp flatten_array(list, depth), do: Enum.flat_map(list, &flat_item(&1, depth))

  defp flat_item(value, 0), do: [value]

  defp flat_item(value, :infinity) do
    case flattenable_array(value) do
      {:ok, list} -> flatten_array(list, :infinity)
      {:array_like, obj} -> flat_array_like(obj, :infinity)
      :error -> [value]
    end
  end

  defp flat_item(value, depth) do
    case flattenable_array(value) do
      {:ok, list} -> flatten_array(list, depth - 1)
      {:array_like, obj} -> flat_array_like(obj, depth - 1)
      :error -> [value]
    end
  end

  defp flat_item(value), do: flat_item(value, 1)

  defp flattenable_array({:qb_arr, arr}), do: {:ok, :array.to_list(arr)}
  defp flattenable_array(a) when is_list(a), do: {:ok, a}

  defp flattenable_array({:obj, ref} = obj) do
    case Heap.get_obj(ref) do
      {:qb_arr, arr} -> {:ok, :array.to_list(arr)}
      a when is_list(a) -> {:ok, a}
      _ -> if(is_array(obj), do: {:array_like, obj}, else: :error)
    end
  end

  defp flattenable_array(_), do: :error

  defp flat_map(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp flat_map(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp flat_map({:qb_arr, arr}, args), do: flat_map(:array.to_list(arr), args)
  defp flat_map(value, args), do: flat_map_array_like(find_receiver(value), args)

  defp flat_map_array_like(this, [fun | rest]) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("mapperFunction must be callable")
    end

    this_arg = filter_this_arg(rest)
    target = filter_target(this)

    result =
      if len == 0 do
        []
      else
        0..(len - 1)
        |> Enum.flat_map(fn idx ->
          key = Integer.to_string(idx)

          if HasProperty.has_property?(this, key) do
            value = find_value_at(this, idx)

            fun
            |> flat_map_callback()
            |> QuickBEAM.VM.Invocation.invoke_with_receiver([value, idx, this], this_arg)
            |> flat_item()
          else
            []
          end
        end)
      end

    populate_flat_result(target, result)
  end

  defp flat_map_array_like(this, _args) do
    _len = array_like_length(this)
    JSThrow.type_error!("mapperFunction must be callable")
  end

  defp flat_map_callback(%QuickBEAM.VM.Function{} = fun), do: %{fun | is_strict_mode: true}

  defp flat_map_callback({:closure, captured, %QuickBEAM.VM.Function{} = fun}),
    do: {:closure, captured, %{fun | is_strict_mode: true}}

  defp flat_map_callback(fun), do: fun

  defp fill(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp fill(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp fill({:obj, ref} = obj, args) do
    case Heap.get_obj(ref) do
      list when is_list(list) ->
        new_list = fill_list(list, args, array_like_length(obj))
        Heap.put_obj(ref, new_list)

      {:qb_arr, arr} ->
        new_list = fill_list(:array.to_list(arr), args, array_like_length(obj))
        Heap.put_obj(ref, new_list)

      %{typed_array() => true} ->
        fill_typed_array(obj, args)

      _ ->
        fill_object(obj, args)
    end

    {:obj, ref}
  end

  defp fill({:qb_arr, arr}, args), do: fill(:array.to_list(arr), args)

  defp fill(list, args) when is_list(list), do: fill_list(list, args, length(list))

  defp fill(value, args) when is_boolean(value) or is_number(value) or is_binary(value) do
    value
    |> primitive_object()
    |> fill(args)
  end

  defp fill(_, _), do: :undefined

  defp fill_list(list, args, len) do
    val = arg(args, 0, :undefined)
    start_idx = fill_start(arg(args, 1, :undefined), len)
    end_idx = fill_end(arg(args, 2, :undefined), len)

    Enum.with_index(list, fn item, idx ->
      if idx >= start_idx and idx < end_idx, do: val, else: item
    end)
  end

  defp fill_object(obj, args) do
    len = array_like_length(obj)
    val = arg(args, 0, :undefined)
    start_idx = fill_start(arg(args, 1, :undefined), len)
    end_idx = fill_end(arg(args, 2, :undefined), len)
    fill_object_indices(obj, val, start_idx, end_idx)
  end

  defp fill_typed_array(obj, args) do
    len = array_like_length(obj)
    val = typed_array_fill_value(arg(args, 0, :undefined))
    start_idx = fill_start(arg(args, 1, :undefined), len)
    end_idx = fill_end(arg(args, 2, :undefined), len)

    if start_idx < end_idx do
      Enum.each(start_idx..(end_idx - 1), fn idx ->
        QuickBEAM.VM.Runtime.TypedArray.set_element(obj, idx, val)
      end)
    end
  end

  defp typed_array_fill_value({:bigint, _} = value), do: value
  defp typed_array_fill_value(value) when is_number(value), do: value
  defp typed_array_fill_value(value), do: Runtime.to_number(value)

  defp fill_object_indices(_obj, _val, idx, end_idx) when idx >= end_idx, do: :ok

  defp fill_object_indices(obj, val, idx, end_idx) do
    Put.put(obj, Integer.to_string(idx), val)
    fill_object_indices(obj, val, idx + 1, end_idx)
  end

  defp fill_start(:undefined, _len), do: 0
  defp fill_start(:neg_infinity, _len), do: 0
  defp fill_start(:infinity, len), do: len

  defp fill_start(value, len) do
    index = to_integer_or_infinity(value)
    if index < 0, do: max(len + index, 0), else: min(index, len)
  end

  defp fill_end(:undefined, len), do: len
  defp fill_end(:infinity, len), do: len
  defp fill_end(:neg_infinity, _len), do: 0

  defp fill_end(value, len) do
    index = to_integer_or_infinity(value)
    if index < 0, do: max(len + index, 0), else: min(index, len)
  end

  # ── Predicates ──

  defp find(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp find(:undefined, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp find(value, args), do: find_array_like(find_receiver(value), args, :value)

  defp find_index(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp find_index(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp find_index(value, args), do: find_array_like(find_receiver(value), args, :index)

  defp find_last(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp find_last(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp find_last(value, args), do: find_array_like(find_receiver(value), args, :last_value)

  defp find_last_index(nil, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp find_last_index(:undefined, _),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp find_last_index(value, args), do: find_array_like(find_receiver(value), args, :last_index)

  defp find_receiver(value) when is_boolean(value) or is_number(value) or is_binary(value),
    do: primitive_object(value)

  defp find_receiver({:symbol, _} = value), do: primitive_object(value)
  defp find_receiver({:symbol, _, _} = value), do: primitive_object(value)
  defp find_receiver({:bigint, _} = value), do: primitive_object(value)

  defp find_receiver({:qb_arr, arr}), do: :array.to_list(arr)
  defp find_receiver(value), do: value

  defp find_array_like(this, [fun | rest], result_kind) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("predicate must be callable")
    end

    this_arg = filter_this_arg(rest)

    find_indexes(len, result_kind)
    |> Enum.find_value(default_find_result(result_kind), fn idx ->
      value = find_value_at(this, idx)

      if Runtime.truthy?(
           QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [value, idx, this], this_arg)
         ) do
        find_result(result_kind, value, idx)
      end
    end)
  end

  defp find_array_like(this, _args, _result_kind) do
    _len = array_like_length(this)
    JSThrow.type_error!("predicate must be callable")
  end

  defp find_value_at(list, idx) when is_list(list), do: Enum.at(list, idx, :undefined)

  defp find_value_at({:obj, _} = value, idx) do
    key = Integer.to_string(idx)
    current = Get.get(value, key)

    if current == :undefined and not OwnProperty.present?(value, key) do
      case Prototype.get(value) do
        {:obj, _} = proto -> Get.get(proto, key)
        _ -> current
      end
    else
      current
    end
  end

  defp find_value_at(value, idx), do: Get.get(value, Integer.to_string(idx))

  defp find_indexes(0, _result_kind), do: []
  defp find_indexes(len, kind) when kind in [:last_value, :last_index], do: (len - 1)..0//-1
  defp find_indexes(len, _kind), do: 0..(len - 1)

  defp default_find_result(:value), do: :undefined
  defp default_find_result(:last_value), do: :undefined
  defp default_find_result(:index), do: -1
  defp default_find_result(:last_index), do: -1
  defp find_result(:value, value, _idx), do: value
  defp find_result(:last_value, value, _idx), do: value
  defp find_result(:index, _value, idx), do: idx
  defp find_result(:last_index, _value, idx), do: idx

  defp every(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp every(:undefined, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp every({:obj, _} = obj, args), do: every_array_like(obj, args)
  defp every({:builtin, _, _} = obj, args), do: every_array_like(obj, args)
  defp every({:regexp, _, _, _} = obj, args), do: every_array_like(obj, args)
  defp every({:regexp, _, _} = obj, args), do: every_array_like(obj, args)

  defp every(callable, args) do
    if QuickBEAM.VM.Builtin.callable?(callable) do
      every_array_like(callable, args)
    else
      every_non_callable(callable, args)
    end
  end

  defp every_non_callable(value, args)
       when is_boolean(value) or is_number(value) or is_binary(value) do
    value
    |> primitive_object()
    |> every_array_like(args)
  end

  defp every_non_callable({:qb_arr, arr}, args), do: every_non_callable(:array.to_list(arr), args)

  defp every_non_callable(list, [fun | rest]) when is_list(list) do
    len = length(list)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg =
      case rest do
        [value | _] -> value
        _ -> :undefined
      end

    list
    |> Enum.take(len)
    |> Enum.with_index()
    |> Enum.all?(fn {val, idx} ->
      Runtime.truthy?(
        QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [val, idx, list], this_arg)
      )
    end)
  end

  defp every_non_callable(_, _), do: JSThrow.type_error!("callbackfn is not a function")

  defp every_array_like(this, [fun | rest]) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg =
      case rest do
        [value | _] -> value
        _ -> :undefined
      end

    if len == 0 do
      true
    else
      Enum.all?(0..(len - 1), fn idx ->
        key = Integer.to_string(idx)

        if HasProperty.has_property?(this, key) do
          value = Get.get(this, key)

          Runtime.truthy?(
            QuickBEAM.VM.Invocation.invoke_with_receiver(fun, [value, idx, this], this_arg)
          )
        else
          true
        end
      end)
    end
  end

  defp every_array_like(this, _args) do
    _len = array_like_length(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  defp primitive_object(value),
    do: QuickBEAM.VM.Runtime.Globals.Constructors.object([value], nil)

  defp array_like_length({:obj, ref}) do
    if Heap.get_array_prop(ref, "__arguments__") == true do
      to_length(Get.get({:obj, ref}, "length"))
    else
      case Heap.get_obj(ref) do
        {:qb_arr, _arr} ->
          to_length(Get.length_of({:obj, ref}))

        list when is_list(list) ->
          to_length(Get.length_of({:obj, ref}))

        _ ->
          array_like_object_length({:obj, ref})
      end
    end
  end

  defp array_like_length({:qb_arr, arr}), do: :array.size(arr)
  defp array_like_length(list) when is_list(list), do: length(list)
  defp array_like_length(value), do: to_length(Get.get(value, "length"))

  defp array_like_object_length(obj) do
    length = to_length(Get.get(obj, "length"))

    if length == 0 and not OwnProperty.present?(obj, "length") do
      case Prototype.get(obj) do
        {:obj, _} = proto -> max(length, to_length(Get.get(proto, "length")))
        _ -> length
      end
    else
      length
    end
  end

  defp to_length(value) do
    case Runtime.to_number(value) do
      :infinity -> @max_safe_integer
      :neg_infinity -> 0
      :nan -> 0
      number when is_number(number) -> min(max(trunc(number), 0), @max_safe_integer)
      _ -> 0
    end
  end

  defp to_integer_or_infinity(value) do
    case Runtime.to_number(value) do
      :infinity -> :infinity
      :neg_infinity -> :neg_infinity
      :nan -> 0
      number when is_number(number) -> trunc(number)
      _ -> 0
    end
  end

  defp some(nil, _args), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp some(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp some(value, args), do: some_array_like(find_receiver(value), args)

  defp some_array_like(this, [fun | rest]) do
    len = array_like_length(this)

    unless QuickBEAM.VM.Builtin.callable?(fun) do
      JSThrow.type_error!("callbackfn is not a function")
    end

    this_arg = filter_this_arg(rest)

    if len == 0 do
      false
    else
      Enum.any?(0..(len - 1), fn idx ->
        key = Integer.to_string(idx)

        HasProperty.has_property?(this, key) and
          Runtime.truthy?(
            QuickBEAM.VM.Invocation.invoke_with_receiver(
              fun,
              [find_value_at(this, idx), idx, this],
              this_arg
            )
          )
      end)
    end
  end

  defp some_array_like(this, _args) do
    _len = array_like_length(this)
    JSThrow.type_error!("callbackfn is not a function")
  end

  # ── Array.from ──

  defp from(args, constructor) do
    {source, map_fn} =
      case args do
        [s, f | _] when f != :undefined and f != nil -> {s, f}
        [s, _ | _] -> {s, nil}
        [s] -> {s, nil}
        _ -> {nil, nil}
      end

    if length(args) >= 2 do
      raw_mapfn = Enum.at(args, 1)

      if raw_mapfn != :undefined and not QuickBEAM.VM.Builtin.callable?(raw_mapfn) do
        throw({:js_throw, Heap.make_error("mapFn is not a function", "TypeError")})
      end
    end

    this_arg = Enum.at(args, 2, :undefined)

    result =
      cond do
        iterator_source?(source) and constructable_from?(constructor) and
            not match?({:builtin, "Array", _}, constructor) ->
          target = QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, [])
          count = iterator_to_target(array_from_iterator(source), target, map_fn, this_arg, 0)
          Put.put(target, "length", count)
          {:target, target}

        iterator_source?(source) ->
          {:list, iterator_to_list(array_from_iterator(source), [], map_fn, this_arg, 0), []}

        array_like_source?(source) ->
          len = array_like_length(source)
          {:list, array_like_from(source, map_fn, this_arg), [len]}

        true ->
          list = coerce_to_list(source)

          result =
            if map_fn do
              Enum.map(Enum.with_index(list), fn {val, idx} ->
                QuickBEAM.VM.Invocation.invoke_with_receiver(map_fn, [val, idx], this_arg)
              end)
            else
              list
            end

          {:list, result, [length(result)]}
      end

    case result do
      {:target, target} -> target
      {:list, list, construct_args} -> from_result(list, constructor, construct_args)
    end
  end

  defp from_result(list, {:builtin, "Array", _}, _construct_args), do: wrap_array_result(list)

  defp from_result(list, constructor, _construct_args) when constructor in [nil, :undefined],
    do: wrap_array_result(list)

  defp from_result(list, constructor, construct_args) do
    if constructable_from?(constructor) do
      target = QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, construct_args)

      Enum.each(Enum.with_index(list), fn {value, index} ->
        create_data_property_or_throw(target, Integer.to_string(index), value)
      end)

      Put.put(target, "length", length(list))
      target
    else
      Heap.wrap(list)
    end
  end

  defp wrap_array_result(list) do
    {:obj, ref} = array = Heap.wrap(list)

    list
    |> Enum.with_index()
    |> Enum.each(fn
      {:undefined, index} -> mark_array_result_present(ref, index)
      {value, index} when value == :undefined -> mark_array_result_present(ref, index)
      _ -> :ok
    end)

    array
  end

  defp mark_array_result_present(ref, index) when is_integer(index) do
    mark_array_result_present(ref, Integer.to_string(index))
  end

  defp mark_array_result_present(ref, key) do
    Heap.put_prop_desc(ref, key, %{
      writable: true,
      enumerable: true,
      configurable: true
    })
  end

  defp create_data_property_or_throw({:obj, ref} = target, key, value) do
    desc = %{"value" => value, "writable" => true, "enumerable" => true, "configurable" => true}
    result = Define.property(target, key, Heap.wrap(desc), desc)

    if value == :undefined do
      Heap.put_array_prop(ref, key, value)
      mark_array_result_present(ref, key)
    end

    result
  end

  defp create_data_property_or_throw(target, key, value) do
    desc = %{"value" => value, "writable" => true, "enumerable" => true, "configurable" => true}
    Define.property(target, key, Heap.wrap(desc), desc)
  end

  defp constructable_from?({:builtin, name, _} = builtin) do
    case QuickBEAM.VM.Builtin.named_meta(name) do
      %QuickBEAM.VM.Builtin.Meta{constructable?: true} -> true
      %QuickBEAM.VM.Builtin.Meta{constructable?: false} -> false
      _ -> Heap.get_class_proto(builtin) != nil
    end
  end

  defp constructable_from?(%QuickBEAM.VM.Function{has_prototype: true}), do: true
  defp constructable_from?({:closure, _, %QuickBEAM.VM.Function{has_prototype: true}}), do: true

  defp constructable_from?({:bound, _, _inner, orig_fun, _bound_args}),
    do: constructable_from?(orig_fun)

  defp constructable_from?(_), do: false

  defp coerce_to_list({:obj, ref} = obj) do
    iterator_method = Get.get(obj, {:symbol, "Symbol.iterator"})

    cond do
      QuickBEAM.VM.Builtin.callable?(iterator_method) ->
        iterator = QuickBEAM.VM.Invocation.invoke_with_receiver(iterator_method, [], obj)
        iterator_to_list(iterator, [])

      iterator_method not in [nil, :undefined] ->
        JSThrow.type_error!("object is not iterable")

      true ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.to_list(arr)
          l when is_list(l) -> l
          _ -> array_like_to_list(obj)
        end
    end
  end

  defp coerce_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  defp coerce_to_list(l) when is_list(l), do: l
  defp coerce_to_list(s) when is_binary(s), do: String.codepoints(s)

  defp coerce_to_list(nil),
    do: throw({:js_throw, Heap.make_error("Cannot convert null to object", "TypeError")})

  defp coerce_to_list(:undefined),
    do: throw({:js_throw, Heap.make_error("Cannot convert undefined to object", "TypeError")})

  defp coerce_to_list(n) when is_number(n), do: []
  defp coerce_to_list(b) when is_boolean(b), do: []
  defp coerce_to_list(_), do: []

  defp array_like_source?({:obj, _} = obj) do
    iterator_method = Get.get(obj, {:symbol, "Symbol.iterator"})

    cond do
      QuickBEAM.VM.Builtin.callable?(iterator_method) -> false
      iterator_like_source?(obj) -> false
      iterator_method not in [nil, :undefined] -> false
      true -> true
    end
  end

  defp array_like_source?(_), do: false

  defp iterator_source?({:obj, _} = obj) do
    QuickBEAM.VM.Builtin.callable?(Get.get(obj, {:symbol, "Symbol.iterator"})) or
      iterator_like_source?(obj)
  end

  defp iterator_source?({:qb_arr, _}), do: true
  defp iterator_source?(list) when is_list(list), do: true
  defp iterator_source?(_), do: false

  defp array_from_iterator({:obj, _} = obj) do
    iterator_method = Get.get(obj, {:symbol, "Symbol.iterator"})

    if QuickBEAM.VM.Builtin.callable?(iterator_method) do
      QuickBEAM.VM.Invocation.invoke_with_receiver(iterator_method, [], obj)
    else
      obj
    end
  end

  defp array_from_iterator(value), do: value

  defp iterator_like_source?({:obj, _} = obj),
    do:
      QuickBEAM.VM.Builtin.callable?(Get.get(obj, "next")) and
        Get.get(obj, "length") in [nil, :undefined]

  defp array_like_to_list(obj) do
    len = max(Runtime.to_int(Get.get(obj, "length")), 0)

    if len == 0 do
      []
    else
      for index <- 0..(len - 1), do: Get.get(obj, Integer.to_string(index))
    end
  end

  defp array_like_from(obj, map_fn, this_arg) do
    len = max(Runtime.to_int(Get.get(obj, "length")), 0)

    if len == 0 do
      []
    else
      for index <- 0..(len - 1) do
        value = Get.get(obj, Integer.to_string(index))

        if map_fn do
          QuickBEAM.VM.Invocation.invoke_with_receiver(map_fn, [value, index], this_arg)
        else
          value
        end
      end
    end
  end

  defp iterator_to_list(iterator, acc), do: iterator_to_list(iterator, acc, nil, :undefined, 0)

  defp iterator_to_target(iterator, target, map_fn, this_arg, index) do
    next_fn = Get.get(iterator, "next")

    unless QuickBEAM.VM.Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = QuickBEAM.VM.Invocation.invoke_with_receiver(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      JSThrow.type_error!("Iterator result is not an object")
    end

    if Get.get(result, "done") == true do
      index
    else
      value = Get.get(result, "value")

      mapped = map_iterator_value(value, index, map_fn, this_arg, iterator)

      try do
        create_data_property_or_throw(target, Integer.to_string(index), mapped)
      catch
        {:js_throw, _} = thrown ->
          close_iterator(iterator)
          throw(thrown)
      end

      iterator_to_target(iterator, target, map_fn, this_arg, index + 1)
    end
  end

  defp map_iterator_value(value, _index, nil, _this_arg, _iterator), do: value

  defp map_iterator_value(value, index, map_fn, this_arg, iterator) do
    try do
      QuickBEAM.VM.Invocation.invoke_with_receiver(map_fn, [value, index], this_arg)
    catch
      {:js_throw, _} = thrown ->
        close_iterator(iterator)
        throw(thrown)
    end
  end

  defp close_iterator(iterator) do
    return_fn = Get.get(iterator, "return")

    if QuickBEAM.VM.Builtin.callable?(return_fn) do
      QuickBEAM.VM.Invocation.invoke_with_receiver(return_fn, [], iterator)
    end
  end

  defp iterator_to_list(iterator, acc, map_fn, this_arg, index) do
    next_fn = Get.get(iterator, "next")

    unless QuickBEAM.VM.Builtin.callable?(next_fn) do
      JSThrow.type_error!("Iterator next is not callable")
    end

    result = QuickBEAM.VM.Invocation.invoke_with_receiver(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      JSThrow.type_error!("Iterator result is not an object")
    end

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      value = Get.get(result, "value")

      mapped = map_iterator_value(value, index, map_fn, this_arg, iterator)

      iterator_to_list(iterator, [mapped | acc], map_fn, this_arg, index + 1)
    end
  end

  defp copy_within(nil, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp copy_within(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp copy_within(value, _args) when is_boolean(value), do: primitive_object(value)

  defp copy_within({:obj, ref} = obj, args) do
    case Heap.get_obj(ref) do
      map when is_map(map) ->
        copy_within_object(obj, args)

      _ ->
        list = Heap.obj_to_list(ref)
        len = copy_within_length!(obj, ref, list)
        target = normalize_copy_index(arg(args, 0, 0), len)
        start_idx = normalize_copy_index(arg(args, 1, 0), len)

        end_idx =
          case Enum.drop(args, 2) do
            [] -> len
            [:undefined | _] -> len
            [end_value | _] -> normalize_copy_index(end_value, len)
          end

        current_len = Runtime.to_int(Get.get(obj, "length"))

        if current_len != len and start_idx >= current_len do
          copy_within_from_sparse_source(obj, ref, len, current_len, target, start_idx)
        else
          if current_len != len and target >= current_len do
            copy_within_sparse_tail(obj, ref, target, start_idx, current_len)
          else
            if copy_within_source_has_holes?(obj, start_idx, end_idx, len, target) do
              copy_within_present_properties(obj, len, target, start_idx, end_idx)
            else
              slice = Enum.slice(list, start_idx, max(end_idx - start_idx, 0))

              new_list =
                list
                |> Enum.with_index()
                |> Enum.map(fn {item, i} ->
                  offset = i - target

                  if i >= target and offset < length(slice),
                    do: Enum.at(slice, offset),
                    else: item
                end)

              Heap.put_obj(ref, new_list)
              {:obj, ref}
            end
          end
        end
    end
  end

  defp copy_within(_, _), do: :undefined

  defp copy_within_source_has_holes?(obj, start_idx, end_idx, len, target) do
    count = max(min(max(end_idx - start_idx, 0), len - target), 0)

    count > 0 and
      Enum.any?(0..(count - 1)//1, fn offset ->
        not HasProperty.has_property?(obj, Integer.to_string(start_idx + offset))
      end)
  end

  defp copy_within_present_properties(obj, len, target, start_idx, end_idx) do
    count = max(min(max(end_idx - start_idx, 0), len - target), 0)

    {from, to, step} =
      if start_idx < target and target < start_idx + count do
        {start_idx + count - 1, target + count - 1, -1}
      else
        {start_idx, target, 1}
      end

    _final_position =
      Enum.reduce(0..max(count - 1, 0)//1, {from, to}, fn _offset, {from_idx, to_idx} ->
        from_key = Integer.to_string(from_idx)
        to_key = Integer.to_string(to_idx)

        if HasProperty.has_property?(obj, from_key) do
          Put.put(obj, to_key, Get.get(obj, from_key))
        else
          unless Delete.delete_property(obj, to_key) do
            JSThrow.type_error!("Cannot delete property")
          end
        end

        {from_idx + step, to_idx + step}
      end)

    obj
  end

  defp copy_within_from_sparse_source(obj, ref, len, current_len, target, start_idx) do
    count = max(min(len - start_idx, len - target), 0)

    Enum.each(0..max(count - 1, -1), fn offset ->
      from_key = Integer.to_string(start_idx + offset)
      to = target + offset
      to_key = Integer.to_string(to)

      if HasProperty.has_property?(obj, from_key) do
        value =
          copy_within_sparse_source_value(obj, ref, start_idx + offset, current_len, from_key)

        if to < current_len do
          Put.put(obj, to_key, value)
        else
          Heap.put_array_prop(ref, to_key, value)
          Heap.put_array_prop(ref, "length", to + 1)
        end
      else
        if to < current_len do
          unless Delete.delete_property(obj, to_key) do
            JSThrow.type_error!("Cannot delete property")
          end
        end
      end
    end)

    obj
  end

  defp copy_within_sparse_source_value(obj, ref, idx, current_len, key) do
    if idx >= current_len do
      case Prototype.get({:obj, ref}) do
        {:obj, _} = proto -> Get.get(proto, key)
        _ -> Get.get(obj, key)
      end
    else
      Get.get(obj, key)
    end
  end

  defp copy_within_sparse_tail(obj, ref, target, start_idx, current_len) do
    count = max(current_len - start_idx, 0)

    Enum.each(0..max(count - 1, -1), fn offset ->
      from_key = Integer.to_string(start_idx + offset)

      if HasProperty.has_property?(obj, from_key) do
        Heap.put_array_prop(ref, Integer.to_string(target + offset), Get.get(obj, from_key))
      end
    end)

    if count > 0, do: Heap.put_array_prop(ref, "length", target + count)
    obj
  end

  defp copy_within_object({:obj, ref} = obj, args) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} -> copy_within_typed_array(obj, args)
      _ -> copy_within_ordinary_object(obj, args)
    end
  end

  defp copy_within_object(obj, args), do: copy_within_ordinary_object(obj, args)

  defp copy_within_typed_array(obj, args) do
    if QuickBEAM.VM.Runtime.TypedArray.out_of_bounds?(obj) do
      obj
    else
      len = QuickBEAM.VM.Runtime.TypedArray.element_count(obj)
      target = normalize_copy_index(arg(args, 0, 0), len)
      start_idx = normalize_copy_index(arg(args, 1, 0), len)

      end_idx =
        case Enum.drop(args, 2) do
          [] -> len
          [:undefined | _] -> len
          [end_value | _] -> normalize_copy_index(end_value, len)
        end

      count = max(min(end_idx - start_idx, len - target), 0)

      if count > 0 do
        {from, to, step} =
          if start_idx < target and target < start_idx + count,
            do: {start_idx + count - 1, target + count - 1, -1},
            else: {start_idx, target, 1}

        Enum.reduce(0..(count - 1)//1, {from, to}, fn _offset, {from_idx, to_idx} ->
          value = QuickBEAM.VM.Runtime.TypedArray.get_element(obj, from_idx)
          QuickBEAM.VM.Runtime.TypedArray.set_element(obj, to_idx, value)
          {from_idx + step, to_idx + step}
        end)
      end

      obj
    end
  end

  defp copy_within_ordinary_object(obj, args) do
    len = copy_within_length!(obj)
    target = normalize_copy_index(arg(args, 0, 0), len)
    start_idx = normalize_copy_index(arg(args, 1, 0), len)

    end_idx =
      case Enum.drop(args, 2) do
        [] -> len
        [:undefined | _] -> len
        [end_value | _] -> normalize_copy_index(end_value, len)
      end

    count = max(end_idx - start_idx, 0)

    if count > 0 do
      Enum.reduce(0..(count - 1)//1, obj, fn offset, acc ->
        from_key = Integer.to_string(start_idx + offset)
        to_key = Integer.to_string(target + offset)

        if HasProperty.has_property?(acc, from_key) do
          Put.put(acc, to_key, Get.get(acc, from_key))
        else
          unless Delete.delete_property(acc, to_key) do
            JSThrow.type_error!("Cannot delete property")
          end
        end

        acc
      end)
    end

    obj
  end

  defp copy_within_length!(obj) do
    case Get.get(obj, "length") do
      {:symbol, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a number")
      {:symbol, _, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a number")
      length -> max(Runtime.to_int(length), 0)
    end
  end

  defp copy_within_length!(obj, ref, list) do
    case Heap.get_obj(ref) do
      map when is_map(map) ->
        case Get.get(obj, "length") do
          {:symbol, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a number")
          {:symbol, _, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a number")
          length -> max(Runtime.to_int(length), 0)
        end

      _ ->
        length(list)
    end
  end

  defp normalize_copy_index(:infinity, len), do: len
  defp normalize_copy_index(:neg_infinity, _len), do: 0
  defp normalize_copy_index(value, len), do: Runtime.normalize_index(Runtime.to_int(value), len)

  defp require_object_coercible!(nil),
    do: throw({:js_throw, Heap.make_error("Cannot convert null to object", "TypeError")})

  defp require_object_coercible!(:undefined),
    do: throw({:js_throw, Heap.make_error("Cannot convert undefined to object", "TypeError")})

  defp require_object_coercible!(_), do: :ok

  defp array_at({:obj, ref} = obj, [idx | _]) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        len = QuickBEAM.VM.Runtime.TypedArray.element_count(obj)
        i = Runtime.to_int(idx)
        i = if i < 0, do: len + i, else: i

        cond do
          i < 0 or i >= len -> :undefined
          QuickBEAM.VM.Runtime.TypedArray.out_of_bounds?(obj) -> :undefined
          true -> QuickBEAM.VM.Runtime.TypedArray.get_element(obj, i)
        end

      _ ->
        list = Heap.obj_to_list(ref)
        array_at(list, [idx])
    end
  end

  defp array_at({:qb_arr, arr}, args), do: array_at(:array.to_list(arr), args)

  defp array_at(list, [idx | _]) when is_list(list) do
    i = Runtime.to_int(idx)
    i = if i < 0, do: length(list) + i, else: i
    if i >= 0 and i < length(list), do: Enum.at(list, i), else: :undefined
  end

  defp array_at(_, _), do: :undefined

  defp to_reversed(nil), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_reversed(:undefined),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_reversed(value) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    target = copy_array_target(len)

    if len > 0 do
      0..(len - 1)
      |> Enum.each(fn index ->
        from = len - index - 1

        create_data_property_or_throw(
          target,
          Integer.to_string(index),
          find_value_at(receiver, from)
        )
      end)
    end

    Put.put(target, "length", len)
    target
  end

  defp to_sorted(nil, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_sorted(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_sorted(value, args) do
    compare_fn = sort_compare_fn(args)
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    target = copy_array_target(len)

    values =
      if len == 0 do
        []
      else
        0..(len - 1)
        |> Enum.map(fn index -> {find_value_at(receiver, index), index} end)
        |> sort_values(compare_fn)
      end

    values
    |> Enum.with_index()
    |> Enum.each(fn {{value, _original_index}, index} ->
      create_data_property_or_throw(target, Integer.to_string(index), value)
    end)

    Put.put(target, "length", len)
    target
  end

  defp to_spliced(nil, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_spliced(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp to_spliced(value, args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    actual_start = splice_start(args, len)
    actual_delete_count = splice_delete_count(args, len, actual_start)
    insert = Enum.drop(args, 2)
    new_len = len - actual_delete_count + length(insert)

    if new_len > @max_safe_integer do
      JSThrow.type_error!("Invalid array length")
    end

    target = copy_array_target(new_len)

    copy_prefix(receiver, target, actual_start)

    insert
    |> Enum.with_index(actual_start)
    |> Enum.each(fn {item, index} ->
      create_data_property_or_throw(target, Integer.to_string(index), item)
    end)

    copy_suffix(receiver, target, actual_start, actual_delete_count, length(insert), len)
    Put.put(target, "length", new_len)
    target
  end

  defp array_with(nil, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp array_with(:undefined, _args),
    do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp array_with(value, args) do
    receiver = find_receiver(value)
    len = array_like_length(receiver)
    relative_index = args |> Enum.at(0, :undefined) |> to_integer_or_infinity()
    actual_index = with_actual_index(relative_index, len)

    if actual_index < 0 or actual_index >= len do
      JSThrow.range_error!("Invalid index")
    end

    replacement = Enum.at(args, 1, :undefined)
    target = copy_array_target(len)

    if len > 0 do
      0..(len - 1)
      |> Enum.each(fn index ->
        value = if index == actual_index, do: replacement, else: find_value_at(receiver, index)
        create_data_property_or_throw(target, Integer.to_string(index), value)
      end)
    end

    Put.put(target, "length", len)
    target
  end

  defp with_actual_index(:neg_infinity, len), do: -len - 1
  defp with_actual_index(:infinity, len), do: len
  defp with_actual_index(index, len) when index < 0, do: len + index
  defp with_actual_index(index, _len), do: index

  defp copy_array_target(len) do
    if len > @max_array_length do
      JSThrow.range_error!("Invalid array length")
    end

    Heap.wrap([])
  end

  defp copy_prefix(_receiver, _target, 0), do: :ok

  defp copy_prefix(receiver, target, count) do
    0..(count - 1)
    |> Enum.each(fn index ->
      create_data_property_or_throw(
        target,
        Integer.to_string(index),
        find_value_at(receiver, index)
      )
    end)
  end

  defp copy_suffix(_receiver, _target, actual_start, actual_delete_count, insert_count, len)
       when actual_start + actual_delete_count >= len and insert_count >= 0,
       do: :ok

  defp copy_suffix(receiver, target, actual_start, actual_delete_count, insert_count, len) do
    from_start = actual_start + actual_delete_count
    to_start = actual_start + insert_count

    from_start..(len - 1)
    |> Enum.each(fn from ->
      to = to_start + from - from_start
      create_data_property_or_throw(target, Integer.to_string(to), find_value_at(receiver, from))
    end)
  end

  defp make_array_iterator(arr, mode) do
    list_fn = array_iterator_list_fn(arr)
    idx_ref = :atomics.new(2, signed: false)

    next_fn =
      {:builtin, "next",
       fn _args, _this ->
         i = :atomics.get(idx_ref, 1)
         done = :atomics.get(idx_ref, 2) == 1
         list = list_fn.()

         cond do
           done ->
             Heap.wrap(%{"value" => :undefined, "done" => true})

           i >= length(list) ->
             :atomics.put(idx_ref, 2, 1)
             Heap.wrap(%{"value" => :undefined, "done" => true})

           true ->
             :atomics.put(idx_ref, 1, i + 1)

             value =
               case mode do
                 :values -> Enum.at(list, i, :undefined)
                 :keys -> i
                 :entries -> Heap.wrap([i, Enum.at(list, i, :undefined)])
               end

             Heap.wrap(%{"value" => value, "done" => false})
         end
       end}

    object do
      prop("next", next_fn)

      symbol_method "Symbol.iterator" do
        this
      end
    end
  end

  defp array_iterator_list_fn({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        fn ->
          if QuickBEAM.VM.Runtime.TypedArray.out_of_bounds?(obj) do
            JSThrow.type_error!("TypedArray is out of bounds")
          end

          count = QuickBEAM.VM.Runtime.TypedArray.element_count(obj)

          if count > 0 do
            for i <- 0..(count - 1), do: QuickBEAM.VM.Runtime.TypedArray.get_element(obj, i)
          else
            []
          end
        end

      _ ->
        fn -> Heap.obj_to_list(ref) end
    end
  end

  defp array_iterator_list_fn({:qb_arr, arr}), do: fn -> :array.to_list(arr) end
  defp array_iterator_list_fn(list) when is_list(list), do: fn -> list end

  defp array_iterator_list_fn(string) when is_binary(string),
    do: fn -> String.codepoints(string) end

  defp array_iterator_list_fn(_), do: fn -> [] end
end
