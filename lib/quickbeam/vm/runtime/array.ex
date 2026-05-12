defmodule QuickBEAM.VM.Runtime.Array do
  @moduledoc "Array.prototype and Array static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Define, Delete, Get, Put}
  alias QuickBEAM.VM.PromiseState
  alias QuickBEAM.VM.Runtime

  @doc "Builds the JavaScript prototype object for this runtime builtin."
  def prototype do
    mod = __MODULE__
    methods = ~w(push pop shift unshift map filter reduce reduceRight forEach indexOf
      lastIndexOf toString includes slice splice join concat reverse sort
      flat find findIndex some every fill copyWithin entries keys values
      at flatMap)

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

      Heap.put_ctor_prop_desc(method, "length", %{
        writable: false,
        enumerable: false,
        configurable: true
      })
    end

    proto = Heap.wrap(proto_map)
    {:obj, ref} = proto

    for name <- methods do
      Heap.put_prop_desc(ref, name, %{writable: true, enumerable: false, configurable: true})
    end

    Heap.put_prop_desc(ref, sym_iter, %{writable: true, enumerable: false, configurable: true})

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
    this |> Heap.to_list() |> Enum.reverse() |> reduce(args)
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
    join(this, [","])
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

  proto "findLast" do
    find_last(this, args)
  end

  proto "findLastIndex" do
    find_last_index(this, args)
  end

  proto "toReversed" do
    to_reversed(this)
  end

  proto "toSorted" do
    to_sorted(this)
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

      Enum.with_index(args, fn value, index ->
        create_data_property_or_throw(target, Integer.to_string(index), value)
      end)

      Put.put(target, "length", length(args))
      target
    else
      Heap.wrap(args)
    end
  end

  # ── Mutation helpers ──

  defp push({:obj, ref}, args) do
    Heap.array_push(ref, args)
  end

  defp push({:qb_arr, arr}, args), do: :array.size(arr) + length(args)
  defp push(list, args) when is_list(list), do: length(list ++ args)

  defp pop({:obj, ref}, _) do
    list = Heap.obj_to_list(ref)

    case List.pop_at(list, -1) do
      {nil, _} ->
        :undefined

      {last, rest} ->
        Heap.put_obj(ref, rest)
        last
    end
  end

  defp pop([_ | _] = list, _), do: List.last(list)
  defp pop(_, _), do: :undefined

  defp shift({:obj, ref}, _) do
    list = Heap.obj_to_list(ref)

    case list do
      [first | rest] ->
        Heap.put_obj(ref, rest)
        first

      _ ->
        :undefined
    end
  end

  defp shift(_, _), do: :undefined

  defp unshift({:obj, ref}, args) do
    list = Heap.obj_to_list(ref)
    new_list = args ++ list
    Heap.put_obj(ref, new_list)
    length(new_list)
  end

  defp unshift(_, _), do: 0

  # ── Higher-order ──

  defp map({:obj, ref}, [fun | _]) do
    list = Heap.obj_to_list(ref)

    result =
      Enum.map(Enum.with_index(list), fn {val, idx} ->
        Runtime.call_callback(fun, [val, idx, list])
      end)

    Heap.wrap(result)
  end

  defp map([_ | _] = list, [fun | _]) do
    Enum.map(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_callback(fun, [val, idx, list])
    end)
  end

  defp map(list, _), do: list

  defp filter({:obj, ref}, [fun | _]) do
    list = Heap.obj_to_list(ref)

    result =
      Enum.filter(Enum.with_index(list), fn {val, idx} ->
        Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
      end)
      |> Enum.map(fn {val, _} -> val end)

    Heap.wrap(result)
  end

  defp filter({:qb_arr, arr}, args), do: filter(:array.to_list(arr), args)

  defp filter(list, [fun | _]) when is_list(list) do
    Enum.filter(Enum.with_index(list), fn {val, idx} ->
      Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
    end)
    |> Enum.map(fn {val, _} -> val end)
  end

  defp filter(list, _), do: list

  defp reduce({:obj, ref}, [fun | rest]) do
    list = Heap.obj_to_list(ref)
    reduce_impl(list, fun, rest)
  end

  defp reduce({:qb_arr, arr}, args), do: reduce(:array.to_list(arr), args)

  defp reduce(list, [fun | rest]) when is_list(list),
    do: reduce_impl(list, fun, rest)

  defp reduce([], [_, init | _]), do: init
  defp reduce([val], _), do: val

  defp reduce_impl(list, fun, rest) do
    {acc, items} =
      case rest do
        [init] -> {init, list}
        _ -> {hd(list), tl(list)}
      end

    Enum.reduce(Enum.with_index(items), acc, fn {val, idx}, a ->
      Runtime.call_callback(fun, [a, val, idx, list])
    end)
  end

  defp for_each({:obj, ref}, [fun | _]) do
    list = Heap.obj_to_list(ref)

    Enum.each(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_callback(fun, [val, idx, list])
    end)

    :undefined
  end

  defp for_each({:qb_arr, arr}, args), do: for_each(:array.to_list(arr), args)

  defp for_each(list, [fun | _]) when is_list(list) do
    Enum.each(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_callback(fun, [val, idx, list])
    end)

    :undefined
  end

  defp for_each(_, _), do: :undefined

  # ── Search ──

  defp index_of({:obj, ref}, args), do: index_of(Heap.obj_to_list(ref), args)

  defp index_of({:qb_arr, arr}, args), do: index_of(:array.to_list(arr), args)

  defp index_of(list, [val | rest]) when is_list(list) do
    from =
      case rest do
        [f] when is_integer(f) and f >= 0 -> f
        _ -> 0
      end

    list
    |> Enum.drop(from)
    |> Enum.find_index(&Runtime.strict_equal?(&1, val))
    |> then(fn
      nil -> -1
      idx -> idx + from
    end)
  end

  defp index_of(_, _), do: -1

  defp last_index_of({:obj, ref}, args), do: last_index_of(Heap.obj_to_list(ref), args)

  defp last_index_of({:qb_arr, arr}, args), do: last_index_of(:array.to_list(arr), args)

  defp last_index_of(list, [val | _]) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(-1, fn {el, i} -> if Runtime.strict_equal?(el, val), do: i end)
  end

  defp last_index_of(_, _), do: -1

  defp includes({:obj, ref}, args), do: includes(Heap.obj_to_list(ref), args)

  defp includes({:qb_arr, arr}, args), do: includes(:array.to_list(arr), args)

  defp includes(list, [val | rest]) when is_list(list) do
    from =
      case rest do
        [f] when is_integer(f) and f >= 0 -> f
        _ -> 0
      end

    list |> Enum.drop(from) |> Enum.any?(&Runtime.strict_equal?(&1, val))
  end

  defp includes(_, _), do: false

  # ── Slice / splice ──

  defp slice({:obj, ref}, args), do: slice(Heap.obj_to_list(ref), args)

  defp slice({:qb_arr, arr}, args), do: slice(:array.to_list(arr), args)

  defp slice(list, args) when is_list(list) do
    {start_idx, end_idx} = slice_args(list, args)
    list |> Enum.slice(start_idx, max(end_idx - start_idx, 0))
  end

  defp slice(_, _), do: []

  defp splice({:obj, ref}, args) do
    list = Heap.obj_to_list(ref)
    {removed, new_list} = do_splice(list, args)
    Heap.put_obj(ref, new_list)
    removed
  end

  defp splice({:qb_arr, arr}, args), do: splice(:array.to_list(arr), args)

  defp splice(list, args) when is_list(list) do
    {removed, _} = do_splice(list, args)
    removed
  end

  defp splice(_, _), do: []

  defp do_splice(list, [start | rest]) do
    s = Runtime.normalize_index(start, length(list))

    {delete_count, insert} =
      case rest do
        [] -> {length(list) - s, []}
        [dc | ins] -> {max(min(Runtime.to_int(dc), length(list) - s), 0), ins}
      end

    {before, after_start} = Enum.split(list, s)
    {removed, remaining} = Enum.split(after_start, delete_count)
    {removed, before ++ insert ++ remaining}
  end

  defp do_splice(list, _), do: {[], list}

  # ── Transform ──

  defp join({:obj, ref}, args), do: join(Heap.obj_to_list(ref), args)

  defp join({:qb_arr, arr}, args), do: join(:array.to_list(arr), args)

  defp join(list, [sep | _]) when is_list(list),
    do: Enum.map_join(list, Runtime.stringify(sep), &array_element_to_string/1)

  defp join(list, []) when is_list(list), do: Enum.map_join(list, ",", &array_element_to_string/1)
  defp join(_, _), do: ""

  defp array_element_to_string(:undefined), do: ""
  defp array_element_to_string(nil), do: ""
  defp array_element_to_string(val), do: Runtime.stringify(val)

  @max_safe_integer 9_007_199_254_740_991

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
    Enum.with_index(entries, fn
      {:present, value}, index ->
        create_data_property_or_throw(target, Integer.to_string(index), value)

      :hole, _index ->
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

        if Put.has_property(value, key) do
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

  defp reverse({:obj, ref}, _) do
    list = Heap.obj_to_list(ref)
    Heap.put_obj(ref, Enum.reverse(list))
    {:obj, ref}
  end

  defp reverse({:qb_arr, arr}, args), do: reverse(:array.to_list(arr), args)

  defp reverse(list, _) when is_list(list), do: Enum.reverse(list)
  defp reverse(_, _), do: []

  defp sort({:obj, ref}, [_compare_fn | _] = args) do
    list = Heap.obj_to_list(ref)
    # Comparator fn returns negative (a<b), 0 (a==b), or positive (a>b)
    # Fall back to string sort if comparator can't be invoked
    sorted =
      try do
        compare_fn = hd(args)

        Enum.sort(list, fn a, b ->
          result = Runtime.call_callback(compare_fn, [a, b])

          case result do
            n when is_number(n) -> n < 0
            _ -> Runtime.stringify(a) < Runtime.stringify(b)
          end
        end)
      catch
        _ -> Enum.sort(list, fn a, b -> Runtime.stringify(a) < Runtime.stringify(b) end)
      end

    Heap.put_obj(ref, sorted)
    {:obj, ref}
  end

  defp sort({:obj, ref}, []) do
    list = Heap.obj_to_list(ref)

    Heap.put_obj(
      ref,
      Enum.sort(list, fn a, b ->
        Runtime.stringify(a) < Runtime.stringify(b)
      end)
    )

    {:obj, ref}
  end

  defp sort({:qb_arr, arr}, args), do: sort(:array.to_list(arr), args)

  defp sort(list, [_ | _]) when is_list(list) do
    Enum.sort(list, fn a, b -> Runtime.stringify(a) < Runtime.stringify(b) end)
  end

  defp sort(list, []) when is_list(list),
    do:
      Enum.sort(list, fn a, b ->
        Runtime.stringify(a) < Runtime.stringify(b)
      end)

  defp flat({:obj, ref}, args), do: flat(Heap.obj_to_list(ref), args)

  defp flat({:qb_arr, arr}, args), do: flat(:array.to_list(arr), args)

  defp flat(list, _) when is_list(list) do
    Enum.flat_map(list, fn
      {:qb_arr, arr} ->
        :array.to_list(arr)

      a when is_list(a) ->
        a

      {:obj, ref} = obj ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.to_list(arr)
          a when is_list(a) -> a
          _ -> [obj]
        end

      val ->
        [val]
    end)
  end

  defp flat(_, _), do: []

  defp flat_map({:obj, ref}, args), do: flat_map(Heap.obj_to_list(ref), args)

  defp flat_map({:qb_arr, arr}, args), do: flat_map(:array.to_list(arr), args)

  defp flat_map(list, [cb | _]) when is_list(list) do
    result =
      Enum.flat_map(Enum.with_index(list), fn {item, idx} ->
        val = Runtime.call_callback(cb, [item, idx, list])

        case val do
          {:obj, r} -> Heap.obj_to_list(r)
          {:qb_arr, arr2} -> :array.to_list(arr2)
          l when is_list(l) -> l
          _ -> [val]
        end
      end)

    Heap.wrap(result)
  end

  defp flat_map(_, _), do: :undefined

  defp fill({:obj, ref}, args) do
    list = Heap.obj_to_list(ref)
    val = arg(args, 0, :undefined)
    start_idx = arg(args, 1, nil) || 0
    end_idx = arg(args, 2, nil) || length(list)

    new_list =
      Enum.with_index(list, fn item, idx ->
        if idx >= start_idx and idx < end_idx, do: val, else: item
      end)

    Heap.put_obj(ref, new_list)
    {:obj, ref}
  end

  defp fill({:qb_arr, arr}, args), do: fill(:array.to_list(arr), args)

  defp fill(list, args) when is_list(list) do
    val = arg(args, 0, :undefined)
    List.duplicate(val, length(list))
  end

  defp fill(_, _), do: :undefined

  # ── Predicates ──

  defp find({:obj, ref}, args), do: find(Heap.obj_to_list(ref), args)

  defp find({:qb_arr, arr}, args), do: find(:array.to_list(arr), args)

  defp find(list, [fun | _]) when is_list(list) do
    Enum.find_value(Enum.with_index(list), :undefined, fn {val, idx} ->
      if Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list])), do: val
    end)
  end

  defp find(_, _), do: :undefined

  defp find_index({:obj, ref}, args), do: find_index(Heap.obj_to_list(ref), args)

  defp find_index({:qb_arr, arr}, args), do: find_index(:array.to_list(arr), args)

  defp find_index(list, [fun | _]) when is_list(list) do
    Enum.find_value(Enum.with_index(list), -1, fn {val, idx} ->
      if Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list])), do: idx
    end)
  end

  defp find_index(_, _), do: -1

  defp every(nil, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")
  defp every(:undefined, _), do: JSThrow.type_error!("Cannot convert undefined or null to object")

  defp every({:obj, _} = obj, args), do: every_array_like(obj, args)

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

        if Put.has_property(this, key) do
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
        {:qb_arr, arr} ->
          :array.size(arr)

        list when is_list(list) ->
          length(list)

        _ ->
          to_length(Get.get({:obj, ref}, "length"))
      end
    end
  end

  defp array_like_length({:qb_arr, arr}), do: :array.size(arr)
  defp array_like_length(list) when is_list(list), do: length(list)
  defp array_like_length(value), do: to_length(Get.get(value, "length"))

  defp to_length(value) do
    case Runtime.to_number(value) do
      :infinity -> @max_safe_integer
      :neg_infinity -> 0
      :nan -> 0
      number when is_number(number) -> min(max(trunc(number), 0), @max_safe_integer)
      _ -> 0
    end
  end

  defp some({:obj, ref}, args), do: some(Heap.obj_to_list(ref), args)

  defp some({:qb_arr, arr}, args), do: some(:array.to_list(arr), args)

  defp some(list, [fun | _]) when is_list(list) do
    Enum.any?(Enum.with_index(list), fn {val, idx} ->
      Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
    end)
  end

  defp some(_, _), do: false

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

  defp from_result(list, {:builtin, "Array", _}, _construct_args), do: Heap.wrap(list)

  defp from_result(list, constructor, _construct_args) when constructor in [nil, :undefined],
    do: Heap.wrap(list)

  defp from_result(list, constructor, construct_args) do
    if constructable_from?(constructor) do
      target = QuickBEAM.VM.Invocation.construct_runtime(constructor, constructor, construct_args)

      Enum.with_index(list, fn value, index ->
        create_data_property_or_throw(target, Integer.to_string(index), value)
      end)

      Put.put(target, "length", length(list))
      target
    else
      Heap.wrap(list)
    end
  end

  defp create_data_property_or_throw(target, key, value) do
    desc = %{"value" => value, "writable" => true, "enumerable" => true, "configurable" => true}
    Define.property(target, key, Heap.wrap(desc), desc)
  end

  defp constructable_from?({:builtin, name, _}) do
    case QuickBEAM.VM.Builtin.named_meta(name) do
      %QuickBEAM.VM.Builtin.Meta{constructable?: true} -> true
      _ -> false
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

  defp iterator_like_source?(_), do: false

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

      mapped =
        if map_fn do
          try do
            QuickBEAM.VM.Invocation.invoke_with_receiver(map_fn, [value, index], this_arg)
          catch
            {:js_throw, _} = thrown ->
              close_iterator(iterator)
              throw(thrown)
          end
        else
          value
        end

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

      mapped =
        if map_fn do
          try do
            QuickBEAM.VM.Invocation.invoke_with_receiver(map_fn, [value, index], this_arg)
          catch
            {:js_throw, _} = thrown ->
              close_iterator(iterator)
              throw(thrown)
          end
        else
          value
        end

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

        slice = Enum.slice(list, start_idx, max(end_idx - start_idx, 0))

        new_list =
          list
          |> Enum.with_index()
          |> Enum.map(fn {item, i} ->
            offset = i - target
            if i >= target and offset < length(slice), do: Enum.at(slice, offset), else: item
          end)

        Heap.put_obj(ref, new_list)
        {:obj, ref}
    end
  end

  defp copy_within(_, _), do: :undefined

  defp copy_within_object(obj, args) do
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

    Enum.reduce(0..max(count - 1, -1), obj, fn offset, acc ->
      from_key = Integer.to_string(start_idx + offset)
      to_key = Integer.to_string(target + offset)

      if Put.has_property(acc, from_key) do
        Put.put(acc, to_key, Get.get(acc, from_key))
      else
        unless Delete.delete_property(acc, to_key) do
          JSThrow.type_error!("Cannot delete property")
        end
      end

      acc
    end)
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

  defp array_at({:obj, ref}, [idx | _]) do
    list = Heap.obj_to_list(ref)
    array_at(list, [idx])
  end

  defp array_at({:qb_arr, arr}, args), do: array_at(:array.to_list(arr), args)

  defp array_at(list, [idx | _]) when is_list(list) do
    i = Runtime.to_int(idx)
    i = if i < 0, do: length(list) + i, else: i
    if i >= 0 and i < length(list), do: Enum.at(list, i), else: :undefined
  end

  defp array_at(_, _), do: :undefined

  defp find_last({:obj, ref}, args), do: find_last(Heap.obj_to_list(ref), args)

  defp find_last({:qb_arr, arr}, args), do: find_last(:array.to_list(arr), args)

  defp find_last(list, [cb | _]) when is_list(list) do
    list
    |> Enum.reverse()
    |> Enum.find(:undefined, fn item ->
      Runtime.call_callback(cb, [item]) |> Runtime.truthy?()
    end)
  end

  defp find_last(_, _), do: :undefined

  defp find_last_index({:obj, ref}, args),
    do: find_last_index(Heap.obj_to_list(ref), args)

  defp find_last_index({:qb_arr, arr}, args), do: find_last_index(:array.to_list(arr), args)

  defp find_last_index(list, [cb | _]) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(-1, fn {item, idx} ->
      if Runtime.call_callback(cb, [item, idx]) |> Runtime.truthy?(), do: idx
    end)
  end

  defp find_last_index(_, _), do: -1

  defp to_reversed({:obj, ref}) do
    list = Heap.obj_to_list(ref)
    Heap.wrap(Enum.reverse(list))
  end

  defp to_reversed(_), do: :undefined

  defp to_sorted({:obj, ref}) do
    list = Heap.obj_to_list(ref)
    new_ref = make_ref()

    Heap.put_obj(
      new_ref,
      Enum.sort(list, fn a, b -> Runtime.stringify(a) <= Runtime.stringify(b) end)
    )

    {:obj, new_ref}
  end

  defp to_sorted(_), do: :undefined

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

  defp array_iterator_list_fn({:obj, ref}), do: fn -> Heap.obj_to_list(ref) end
  defp array_iterator_list_fn({:qb_arr, arr}), do: fn -> :array.to_list(arr) end
  defp array_iterator_list_fn(list) when is_list(list), do: fn -> list end

  defp array_iterator_list_fn(string) when is_binary(string),
    do: fn -> String.codepoints(string) end

  defp array_iterator_list_fn(_), do: fn -> [] end

  # ── Internal ──

  defp slice_args(list, [start, end_]) do
    s = Runtime.normalize_index(start, length(list))

    e =
      if end_ < 0, do: max(length(list) + end_, 0), else: min(Runtime.to_int(end_), length(list))

    {s, e}
  end

  defp slice_args(list, [start]) do
    {Runtime.normalize_index(start, length(list)), length(list)}
  end

  defp slice_args(list, []) do
    {0, length(list)}
  end
end
