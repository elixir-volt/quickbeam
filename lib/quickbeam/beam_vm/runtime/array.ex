defmodule QuickBEAM.BeamVM.Runtime.Array do
  @moduledoc "Array.prototype and Array static methods."

  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime

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
    make_array_iterator(this, :values)
  end

  proto "keys" do
    make_array_iterator(this, :keys)
  end

  proto "entries" do
    make_array_iterator(this, :entries)
  end

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
    throw({:js_throw, Heap.make_error("Maximum call stack size exceeded", "RangeError")})
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array(list, _) when is_list(list), do: true

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array({:obj, ref}, depth) do
    case Heap.get_obj(ref) do
      list when is_list(list) -> true
      %{proxy_target() => target} -> is_array(target, depth + 1)
      _ -> false
    end
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_array(_, _), do: false

  static "from" do
    from(args)
  end

  static "of" do
    args
  end

  # ── Mutation helpers ──

  defp push({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])
    new_list = list ++ args
    Heap.put_obj(ref, new_list)
    length(new_list)
  end

  defp push(list, args) when is_list(list), do: length(list ++ args)

  defp pop({:obj, ref}, _) do
    list = Heap.get_obj(ref, [])

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
    list = Heap.get_obj(ref, [])

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
    list = Heap.get_obj(ref, [])
    new_list = args ++ list
    Heap.put_obj(ref, new_list)
    length(new_list)
  end

  defp unshift(_, _), do: 0

  # ── Higher-order ──

  defp map({:obj, ref}, [fun | _]) do
    list = Heap.get_obj(ref, [])

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
    list = Heap.get_obj(ref, [])

    result =
      Enum.filter(Enum.with_index(list), fn {val, idx} ->
        Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
      end)
      |> Enum.map(fn {val, _} -> val end)

    Heap.wrap(result)
  end

  defp filter(list, [fun | _]) when is_list(list) do
    Enum.filter(Enum.with_index(list), fn {val, idx} ->
      Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
    end)
    |> Enum.map(fn {val, _} -> val end)
  end

  defp filter(list, _), do: list

  defp reduce({:obj, ref}, [fun | rest]) do
    list = Heap.get_obj(ref, [])
    reduce_impl(list, fun, rest)
  end

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
    list = Heap.get_obj(ref, [])

    Enum.each(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_callback(fun, [val, idx, list])
    end)

    :undefined
  end

  defp for_each(list, [fun | _]) when is_list(list) do
    Enum.each(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_callback(fun, [val, idx, list])
    end)

    :undefined
  end

  defp for_each(_, _), do: :undefined

  # ── Search ──

  defp index_of({:obj, ref}, args), do: index_of(Heap.get_obj(ref, []), args)

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

  defp last_index_of({:obj, ref}, args), do: last_index_of(Heap.get_obj(ref, []), args)

  defp last_index_of(list, [val | _]) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(-1, fn {el, i} -> if Runtime.strict_equal?(el, val), do: i end)
  end

  defp last_index_of(_, _), do: -1

  defp includes({:obj, ref}, args), do: includes(Heap.get_obj(ref, []), args)

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

  defp slice({:obj, ref}, args), do: slice(Heap.get_obj(ref, []), args)

  defp slice(list, args) when is_list(list) do
    {start_idx, end_idx} = slice_args(list, args)
    list |> Enum.slice(start_idx, max(end_idx - start_idx, 0))
  end

  defp slice(_, _), do: []

  defp splice({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])
    {removed, new_list} = do_splice(list, args)
    Heap.put_obj(ref, new_list)
    removed
  end

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

  defp join({:obj, ref}, args), do: join(Heap.get_obj(ref, []), args)

  defp join(list, [sep | _]) when is_list(list),
    do: Enum.map_join(list, Runtime.stringify(sep), &array_element_to_string/1)

  defp join(list, []) when is_list(list), do: Enum.map_join(list, ",", &array_element_to_string/1)
  defp join(_, _), do: ""

  defp array_element_to_string(:undefined), do: ""
  defp array_element_to_string(nil), do: ""
  defp array_element_to_string(val), do: Runtime.stringify(val)

  defp concat({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])
    result = Enum.reduce(args, list, &concat_item(&1, &2))
    Heap.wrap(result)
  end

  defp concat(list, args) when is_list(list), do: Enum.reduce(args, list, &concat_item(&1, &2))

  defp concat_item({:obj, r}, acc), do: acc ++ Heap.get_obj(r, [])
  defp concat_item(a, acc) when is_list(a), do: acc ++ a
  defp concat_item(val, acc), do: acc ++ [val]

  defp reverse({:obj, ref}, _) do
    list = Heap.get_obj(ref, [])
    Heap.put_obj(ref, Enum.reverse(list))
    {:obj, ref}
  end

  defp reverse(list, _) when is_list(list), do: Enum.reverse(list)
  defp reverse(_, _), do: []

  defp sort({:obj, ref}, [_compare_fn | _] = args) do
    list = Heap.get_obj(ref, [])
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
    list = Heap.get_obj(ref, [])

    Heap.put_obj(
      ref,
      Enum.sort(list, fn a, b ->
        Runtime.stringify(a) < Runtime.stringify(b)
      end)
    )

    {:obj, ref}
  end

  defp sort(list, [_ | _]) when is_list(list) do
    Enum.sort(list, fn a, b -> Runtime.stringify(a) < Runtime.stringify(b) end)
  end

  defp sort(list, []) when is_list(list),
    do:
      Enum.sort(list, fn a, b ->
        Runtime.stringify(a) < Runtime.stringify(b)
      end)

  defp flat({:obj, ref}, args), do: flat(Heap.get_obj(ref, []), args)

  defp flat(list, _) when is_list(list) do
    Enum.flat_map(list, fn
      a when is_list(a) ->
        a

      {:obj, ref} = obj ->
        case Heap.get_obj(ref) do
          a when is_list(a) -> a
          _ -> [obj]
        end

      val ->
        [val]
    end)
  end

  defp flat(_, _), do: []

  defp flat_map({:obj, ref}, args), do: flat_map(Heap.get_obj(ref, []), args)

  defp flat_map(list, [cb | _]) when is_list(list) do
    result =
      Enum.flat_map(Enum.with_index(list), fn {item, idx} ->
        val = Runtime.call_callback(cb, [item, idx, list])

        case val do
          {:obj, r} ->
            case Heap.get_obj(r, []) do
              l when is_list(l) -> l
              _ -> [val]
            end

          l when is_list(l) ->
            l

          _ ->
            [val]
        end
      end)

    Heap.wrap(result)
  end

  defp flat_map(_, _), do: :undefined

  defp fill({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])

    if is_list(list) do
      val = Enum.at(args, 0, :undefined)
      start_idx = Enum.at(args, 1) || 0
      end_idx = Enum.at(args, 2) || length(list)

      new_list =
        Enum.with_index(list, fn item, idx ->
          if idx >= start_idx and idx < end_idx, do: val, else: item
        end)

      Heap.put_obj(ref, new_list)
      {:obj, ref}
    else
      {:obj, ref}
    end
  end

  defp fill(list, args) when is_list(list) do
    val = Enum.at(args, 0, :undefined)
    List.duplicate(val, length(list))
  end

  defp fill(_, _), do: :undefined

  # ── Predicates ──

  defp find({:obj, ref}, args), do: find(Heap.get_obj(ref, []), args)

  defp find(list, [fun | _]) when is_list(list) do
    Enum.find_value(Enum.with_index(list), :undefined, fn {val, idx} ->
      if Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list])), do: val
    end)
  end

  defp find(_, _), do: :undefined

  defp find_index({:obj, ref}, args), do: find_index(Heap.get_obj(ref, []), args)

  defp find_index(list, [fun | _]) when is_list(list) do
    Enum.find_value(Enum.with_index(list), -1, fn {val, idx} ->
      if Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list])), do: idx
    end)
  end

  defp find_index(_, _), do: -1

  defp every({:obj, ref}, args), do: every(Heap.get_obj(ref, []), args)

  defp every(list, [fun | _]) when is_list(list) do
    Enum.all?(Enum.with_index(list), fn {val, idx} ->
      Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
    end)
  end

  defp every(_, _), do: true

  defp some({:obj, ref}, args), do: some(Heap.get_obj(ref, []), args)

  defp some(list, [fun | _]) when is_list(list) do
    Enum.any?(Enum.with_index(list), fn {val, idx} ->
      Runtime.truthy?(Runtime.call_callback(fun, [val, idx, list]))
    end)
  end

  defp some(_, _), do: false

  # ── Array.from ──

  defp from(args) do
    {source, map_fn} =
      case args do
        [s, f | _] -> {s, f}
        [s] -> {s, nil}
        _ -> {nil, nil}
      end

    list = coerce_to_list(source)

    if map_fn do
      Enum.map(Enum.with_index(list), fn {val, idx} ->
        Runtime.call_callback(map_fn, [val, idx])
      end)
    else
      list
    end
  end

  defp coerce_to_list({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      l when is_list(l) -> l
      map when is_map(map) -> Heap.to_list({:obj, ref})
      _ -> []
    end
  end

  defp coerce_to_list(l) when is_list(l), do: l
  defp coerce_to_list(s) when is_binary(s), do: String.codepoints(s)
  defp coerce_to_list(_), do: []

  defp copy_within({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])

    if is_list(list) do
      len = length(list)
      target = Runtime.normalize_index(Runtime.to_int(Enum.at(args, 0, 0)), len)
      start_idx = Runtime.normalize_index(Runtime.to_int(Enum.at(args, 1, 0)), len)
      end_idx = Runtime.normalize_index(Runtime.to_int(Enum.at(args, 2) || len), len)
      slice = Enum.slice(list, start_idx, end_idx - start_idx)

      new_list =
        list
        |> Enum.with_index()
        |> Enum.map(fn {item, i} ->
          offset = i - target
          if i >= target and offset < length(slice), do: Enum.at(slice, offset), else: item
        end)

      Heap.put_obj(ref, new_list)
      {:obj, ref}
    else
      {:obj, ref}
    end
  end

  defp copy_within(_, _), do: :undefined

  defp array_at({:obj, ref}, [idx | _]) do
    list = Heap.get_obj(ref, [])
    array_at(list, [idx])
  end

  defp array_at(list, [idx | _]) when is_list(list) do
    i = if is_number(idx), do: trunc(idx), else: 0
    i = if i < 0, do: length(list) + i, else: i
    if i >= 0 and i < length(list), do: Enum.at(list, i), else: :undefined
  end

  defp array_at(_, _), do: :undefined

  defp find_last({:obj, ref}, args), do: find_last(Heap.get_obj(ref, []), args)

  defp find_last(list, [cb | _]) when is_list(list) do
    list
    |> Enum.reverse()
    |> Enum.find(:undefined, fn item ->
      Runtime.call_callback(cb, [item]) |> Runtime.truthy?()
    end)
  end

  defp find_last(_, _), do: :undefined

  defp find_last_index({:obj, ref}, args),
    do: find_last_index(Heap.get_obj(ref, []), args)

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
    list = Heap.get_obj(ref, [])

    if is_list(list) do
      Heap.wrap(Enum.reverse(list))
    else
      {:obj, ref}
    end
  end

  defp to_reversed(_), do: :undefined

  defp to_sorted({:obj, ref}) do
    list = Heap.get_obj(ref, [])

    if is_list(list) do
      new_ref = make_ref()

      Heap.put_obj(
        new_ref,
        Enum.sort(list, fn a, b -> Runtime.stringify(a) <= Runtime.stringify(b) end)
      )

      {:obj, new_ref}
    else
      {:obj, ref}
    end
  end

  defp to_sorted(_), do: :undefined

  defp make_array_iterator(arr, mode) do
    list =
      case arr do
        {:obj, ref} ->
          data = Heap.get_obj(ref, [])
          if is_list(data), do: data, else: []

        l when is_list(l) ->
          l

        s when is_binary(s) ->
          String.codepoints(s)

        _ ->
          []
      end

    idx_ref = :atomics.new(1, signed: false)

    next_fn =
      {:builtin, "next",
       fn _args, _this ->
         i = :atomics.get(idx_ref, 1)

         if i >= length(list) do
           Heap.wrap(%{"value" => :undefined, "done" => true})
         else
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

    iter_ref = make_ref()
    Heap.put_obj(iter_ref, %{"next" => next_fn})
    {:obj, iter_ref}
  end

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
