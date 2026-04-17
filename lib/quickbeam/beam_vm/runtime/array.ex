defmodule QuickBEAM.BeamVM.Runtime.Array do
  alias QuickBEAM.BeamVM.Heap
  @moduledoc "Array.prototype and Array static methods."

  alias QuickBEAM.BeamVM.Runtime

  # ── Array.prototype dispatch ──

  def proto_property("push"), do: {:builtin, "push", fn args, this -> push(this, args) end}
  def proto_property("pop"), do: {:builtin, "pop", fn args, this -> pop(this, args) end}
  def proto_property("shift"), do: {:builtin, "shift", fn args, this -> shift(this, args) end}
  def proto_property("unshift"), do: {:builtin, "unshift", fn args, this -> unshift(this, args) end}
  def proto_property("map"), do: {:builtin, "map", fn args, this, interp -> map(this, args, interp) end}
  def proto_property("filter"), do: {:builtin, "filter", fn args, this, interp -> filter(this, args, interp) end}
  def proto_property("reduce"), do: {:builtin, "reduce", fn args, this, interp -> reduce(this, args, interp) end}
  def proto_property("forEach"), do: {:builtin, "forEach", fn args, this, interp -> for_each(this, args, interp) end}
  def proto_property("indexOf"), do: {:builtin, "indexOf", fn args, this -> index_of(this, args) end}
  def proto_property("lastIndexOf"), do: {:builtin, "lastIndexOf", fn args, this -> last_index_of(this, args) end}
  def proto_property("toString"), do: {:builtin, "toString", fn _args, this -> join(this, [","]) end}
  def proto_property("includes"), do: {:builtin, "includes", fn args, this -> includes(this, args) end}
  def proto_property("slice"), do: {:builtin, "slice", fn args, this -> slice(this, args) end}
  def proto_property("splice"), do: {:builtin, "splice", fn args, this -> splice(this, args) end}
  def proto_property("join"), do: {:builtin, "join", fn args, this -> join(this, args) end}
  def proto_property("concat"), do: {:builtin, "concat", fn args, this -> concat(this, args) end}
  def proto_property("reverse"), do: {:builtin, "reverse", fn args, this -> reverse(this, args) end}
  def proto_property("sort"), do: {:builtin, "sort", fn args, this -> sort(this, args) end}
  def proto_property("flat"), do: {:builtin, "flat", fn args, this -> flat(this, args) end}
  def proto_property("find"), do: {:builtin, "find", fn args, this, interp -> find(this, args, interp) end}
  def proto_property("findIndex"), do: {:builtin, "findIndex", fn args, this, interp -> find_index(this, args, interp) end}
  def proto_property("every"), do: {:builtin, "every", fn args, this, interp -> every(this, args, interp) end}
  def proto_property("some"), do: {:builtin, "some", fn args, this, interp -> some(this, args, interp) end}
  def proto_property("flatMap"), do: {:builtin, "flatMap", fn args, this, interp -> flat_map(this, args, interp) end}
  def proto_property("fill"), do: {:builtin, "fill", fn args, this -> fill(this, args) end}
  def proto_property("copyWithin"), do: {:builtin, "copyWithin", fn args, this -> copy_within(this, args) end}
  def proto_property(_), do: :undefined

  # ── Array static dispatch ──

  def static_property("isArray") do
    {:builtin, "isArray", fn [val | _] ->
      case val do
        list when is_list(list) -> true
        {:obj, ref} -> is_list(Heap.get_obj(ref))
        _ -> false
      end
    end}
  end
  def static_property("from"), do: {:builtin, "from", fn args, _this, interp -> from(args, interp) end}
  def static_property("of"), do: {:builtin, "of", fn args -> args end}
  def static_property(_), do: :undefined

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
      {nil, _} -> :undefined
      {last, rest} -> Heap.put_obj(ref, rest); last
    end
  end
  defp pop(list, _) when is_list(list) and length(list) > 0, do: List.last(list)
  defp pop(_, _), do: :undefined

  defp shift({:obj, ref}, _) do
    list = Heap.get_obj(ref, [])
    case list do
      [first | rest] -> Heap.put_obj(ref, rest); first
      _ -> :undefined
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

  defp map({:obj, ref}, [fun | _], interp) do
    list = Heap.get_obj(ref, [])
    result = Enum.map(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_builtin_callback(fun, [val, idx, list], interp)
    end)
    new_ref = make_ref()
    Heap.put_obj(new_ref, result)
    {:obj, new_ref}
  end
  defp map(list, [fun | _], interp) when is_list(list) and length(list) > 0 do
    Enum.map(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_builtin_callback(fun, [val, idx, list], interp)
    end)
  end
  defp map(list, _, _), do: list

  defp filter({:obj, ref}, [fun | _], interp) do
    list = Heap.get_obj(ref, [])
    result = Enum.filter(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end) |> Enum.map(fn {val, _} -> val end)
    new_ref = make_ref()
    Heap.put_obj(new_ref, result)
    {:obj, new_ref}
  end
  defp filter(list, [fun | _], interp) when is_list(list) do
    Enum.filter(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end) |> Enum.map(fn {val, _} -> val end)
  end
  defp filter(list, _, _), do: list

  defp reduce({:obj, ref}, [fun | rest], interp) do
    list = Heap.get_obj(ref, [])
    reduce_impl(list, fun, rest, interp)
  end
  defp reduce(list, [fun | rest], interp) when is_list(list), do: reduce_impl(list, fun, rest, interp)
  defp reduce([], [_, init | _], _), do: init
  defp reduce([val], _, _), do: val

  defp reduce_impl(list, fun, rest, interp) do
    {acc, items} = case rest do
      [init] -> {init, list}
      _ -> {hd(list), tl(list)}
    end
    Enum.reduce(Enum.with_index(items), acc, fn {val, idx}, a ->
      Runtime.call_builtin_callback(fun, [a, val, idx, list], interp)
    end)
  end

  defp for_each({:obj, ref}, [fun | _], interp) do
    list = Heap.get_obj(ref, [])
    Enum.each(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_builtin_callback(fun, [val, idx, list], interp)
    end)
    :undefined
  end
  defp for_each(list, [fun | _], interp) when is_list(list) do
    Enum.each(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_builtin_callback(fun, [val, idx, list], interp)
    end)
    :undefined
  end
  defp for_each(_, _, _), do: :undefined

  # ── Search ──

  defp index_of({:obj, ref}, args), do: index_of(Heap.get_obj(ref, []), args)
  defp index_of(list, [val | rest]) when is_list(list) do
    from = case rest do [f] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    list |> Enum.drop(from) |> Enum.find_index(&Runtime.js_strict_eq(&1, val)) |> then(fn
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
    |> Enum.find_value(-1, fn {el, i} -> if Runtime.js_strict_eq(el, val), do: i end)
  end
  defp last_index_of(_, _), do: -1

  defp includes({:obj, ref}, args), do: includes(Heap.get_obj(ref, []), args)
  defp includes(list, [val | rest]) when is_list(list) do
    from = case rest do [f] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    list |> Enum.drop(from) |> Enum.any?(&Runtime.js_strict_eq(&1, val))
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
    {delete_count, insert} = case rest do
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
  defp join(list, [sep | _]) when is_list(list), do: Enum.map_join(list, Runtime.js_to_string(sep), &Runtime.js_to_string/1)
  defp join(list, []) when is_list(list), do: Enum.map_join(list, ",", &Runtime.js_to_string/1)
  defp join(_, _), do: ""

  defp concat({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])
    result = Enum.reduce(args, list, &concat_item(&1, &2))
    new_ref = make_ref()
    Heap.put_obj(new_ref, result)
    {:obj, new_ref}
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
    sorted = try do
      compare_fn = hd(args)
      Enum.sort(list, fn a, b ->
        result = Runtime.call_builtin_callback(compare_fn, [a, b], :no_interp)
        case result do
          n when is_number(n) -> n < 0
          _ -> Runtime.js_to_string(a) < Runtime.js_to_string(b)
        end
      end)
    catch
      _ -> Enum.sort(list, fn a, b -> Runtime.js_to_string(a) < Runtime.js_to_string(b) end)
    end
    Heap.put_obj(ref, sorted)
    {:obj, ref}
  end
  defp sort({:obj, ref}, []) do
    list = Heap.get_obj(ref, [])
    Heap.put_obj(ref, Enum.sort(list, fn a, b ->
      Runtime.js_to_string(a) < Runtime.js_to_string(b)
    end))
    {:obj, ref}
  end
  defp sort(list, [_ | _]) when is_list(list) do
    Enum.sort(list, fn a, b -> Runtime.js_to_string(a) < Runtime.js_to_string(b) end)
  end
  defp sort(list, []) when is_list(list), do: Enum.sort(list, fn a, b ->
    Runtime.js_to_string(a) < Runtime.js_to_string(b)
  end)

  defp flat({:obj, ref}, args), do: flat(Heap.get_obj(ref, []), args)
  defp flat(list, _) when is_list(list) do
    Enum.flat_map(list, fn
      a when is_list(a) -> a
      {:obj, ref} = obj ->
        case Heap.get_obj(ref) do
          a when is_list(a) -> a
          _ -> [obj]
        end
      val -> [val]
    end)
  end
  defp flat(_, _), do: []

  defp flat_map({:obj, ref}, args, interp), do: flat_map(Heap.get_obj(ref, []), args, interp)
  defp flat_map(list, [cb | _], interp) when is_list(list) do
    result = Enum.flat_map(Enum.with_index(list), fn {item, idx} ->
      val = Runtime.call_builtin_callback(cb, [item, idx, list], interp)
      case val do
        {:obj, r} ->
          case Heap.get_obj(r, []) do
            l when is_list(l) -> l
            _ -> [val]
          end
        l when is_list(l) -> l
        _ -> [val]
      end
    end)
    new_ref = make_ref()
    Heap.put_obj(new_ref, result)
    {:obj, new_ref}
  end
  defp flat_map(_, _, _), do: :undefined

  defp fill({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])
    if is_list(list) do
      val = Enum.at(args, 0, :undefined)
      start_idx = Enum.at(args, 1) || 0
      end_idx = Enum.at(args, 2) || length(list)
      new_list = Enum.with_index(list, fn item, idx ->
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

  defp find({:obj, ref}, args, interp), do: find(Heap.get_obj(ref, []), args, interp)
  defp find(list, [fun | _], interp) when is_list(list) do
    Enum.find_value(Enum.with_index(list), :undefined, fn {val, idx} ->
      if Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp)), do: val
    end)
  end
  defp find(_, _, _), do: :undefined

  defp find_index({:obj, ref}, args, interp), do: find_index(Heap.get_obj(ref, []), args, interp)
  defp find_index(list, [fun | _], interp) when is_list(list) do
    Enum.find_value(Enum.with_index(list), -1, fn {val, idx} ->
      if Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp)), do: idx
    end)
  end
  defp find_index(_, _, _), do: -1

  defp every({:obj, ref}, args, interp), do: every(Heap.get_obj(ref, []), args, interp)
  defp every(list, [fun | _], interp) when is_list(list) do
    Enum.all?(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end)
  end
  defp every(_, _, _), do: true

  defp some({:obj, ref}, args, interp), do: some(Heap.get_obj(ref, []), args, interp)
  defp some(list, [fun | _], interp) when is_list(list) do
    Enum.any?(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end)
  end
  defp some(_, _, _), do: false

  # ── Array.from ──

  defp from(args, interp) do
    {source, map_fn} = case args do
      [s, f | _] -> {s, f}
      [s] -> {s, nil}
      _ -> {nil, nil}
    end
    list = case source do
      {:obj, ref} ->
        stored = Heap.get_obj(ref, %{})
        case stored do
          l when is_list(l) -> l
          map when is_map(map) ->
            len = Map.get(map, "length", 0)
            if len > 0 do
              for i <- 0..(len - 1), do: Map.get(map, Integer.to_string(i), :undefined)
            else
              []
            end
          _ -> []
        end
      l when is_list(l) -> l
      s when is_binary(s) -> String.graphemes(s)
      _ -> []
    end
    if map_fn do
      Enum.map(Enum.with_index(list), fn {val, idx} ->
        Runtime.call_builtin_callback(map_fn, [val, idx], interp)
      end)
    else
      list
    end
  end

  defp copy_within({:obj, ref}, args) do
    list = Heap.get_obj(ref, [])
    if is_list(list) do
      len = length(list)
      target = arr_normalize_index(Enum.at(args, 0, 0), len)
      start_idx = arr_normalize_index(Enum.at(args, 1, 0), len)
      end_idx = arr_normalize_index(Enum.at(args, 2) || len, len)
      slice = Enum.slice(list, start_idx, end_idx - start_idx)
      new_list = list
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

  defp arr_normalize_index(i, len) when is_integer(i) and i < 0, do: max(0, len + i)
  defp arr_normalize_index(i, len) when is_integer(i), do: min(i, len)
  defp arr_normalize_index(_, _), do: 0

  # ── Internal ──

  defp slice_args(list, [start, end_]) do
    s = Runtime.normalize_index(start, length(list))
    e = if end_ < 0, do: max(length(list) + end_, 0), else: min(Runtime.to_int(end_), length(list))
    {s, e}
  end
  defp slice_args(list, [start]) do
    {Runtime.normalize_index(start, length(list)), length(list)}
  end
  defp slice_args(list, []) do
    {0, length(list)}
  end
end
