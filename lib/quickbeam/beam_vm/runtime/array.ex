defmodule QuickBEAM.BeamVM.Runtime.Array do
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
  def proto_property("toString"), do: {:builtin, "toString", fn _args, this -> join(this, [","]) end}
  def proto_property(_), do: :undefined

  # ── Array static dispatch ──

  def static_property("isArray"), do: {:builtin, "isArray", fn [val | _] -> is_list(val) end}
  def static_property("from"), do: {:builtin, "from", fn args -> from(args) end}
  def static_property("of"), do: {:builtin, "of", fn args -> args end}
  def static_property(_), do: :undefined

  # ── Mutation helpers ──

  defp push({:obj, ref}, args) do
    list = Process.get({:qb_obj, ref}, [])
    new_list = list ++ args
    Process.put({:qb_obj, ref}, new_list)
    length(new_list)
  end
  defp push(list, args) when is_list(list), do: length(list ++ args)

  defp pop({:obj, ref}, _) do
    list = Process.get({:qb_obj, ref}, [])
    case List.pop_at(list, -1) do
      {nil, _} -> :undefined
      {last, rest} -> Process.put({:qb_obj, ref}, rest); last
    end
  end
  defp pop(list, _) when is_list(list) and length(list) > 0, do: List.last(list)
  defp pop(_, _), do: :undefined

  defp shift({:obj, ref}, _) do
    list = Process.get({:qb_obj, ref}, [])
    case list do
      [first | rest] -> Process.put({:qb_obj, ref}, rest); first
      _ -> :undefined
    end
  end
  defp shift(_, _), do: :undefined

  defp unshift({:obj, ref}, args) do
    list = Process.get({:qb_obj, ref}, [])
    new_list = args ++ list
    Process.put({:qb_obj, ref}, new_list)
    length(new_list)
  end
  defp unshift(_, _), do: 0

  # ── Higher-order ──

  defp map({:obj, ref}, [fun | _], interp) do
    list = Process.get({:qb_obj, ref}, [])
    result = Enum.map(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_builtin_callback(fun, [val, idx, list], interp)
    end)
    new_ref = System.unique_integer([:positive])
    Process.put({:qb_obj, new_ref}, result)
    {:obj, new_ref}
  end
  defp map(list, [fun | _], interp) when is_list(list) and length(list) > 0 do
    Enum.map(Enum.with_index(list), fn {val, idx} ->
      Runtime.call_builtin_callback(fun, [val, idx, list], interp)
    end)
  end
  defp map(list, _, _), do: list

  defp filter({:obj, ref}, [fun | _], interp) do
    list = Process.get({:qb_obj, ref}, [])
    result = Enum.filter(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end) |> Enum.map(fn {val, _} -> val end)
    new_ref = System.unique_integer([:positive])
    Process.put({:qb_obj, new_ref}, result)
    {:obj, new_ref}
  end
  defp filter(list, [fun | _], interp) when is_list(list) do
    Enum.filter(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end) |> Enum.map(fn {val, _} -> val end)
  end
  defp filter(list, _, _), do: list

  defp reduce({:obj, ref}, [fun | rest], interp) do
    list = Process.get({:qb_obj, ref}, [])
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
    list = Process.get({:qb_obj, ref}, [])
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

  defp index_of({:obj, ref}, args), do: index_of(Process.get({:qb_obj, ref}, []), args)
  defp index_of(list, [val | rest]) when is_list(list) do
    from = case rest do [f] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    list |> Enum.drop(from) |> Enum.find_index(&Runtime.js_strict_eq(&1, val)) |> then(fn
      nil -> -1
      idx -> idx + from
    end)
  end
  defp index_of(_, _), do: -1

  defp includes({:obj, ref}, args), do: includes(Process.get({:qb_obj, ref}, []), args)
  defp includes(list, [val | rest]) when is_list(list) do
    from = case rest do [f] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    list |> Enum.drop(from) |> Enum.any?(&Runtime.js_strict_eq(&1, val))
  end
  defp includes(_, _), do: false

  # ── Slice / splice ──

  defp slice({:obj, ref}, args), do: slice(Process.get({:qb_obj, ref}, []), args)
  defp slice(list, args) when is_list(list) do
    {start_idx, end_idx} = slice_args(list, args)
    list |> Enum.slice(start_idx, max(end_idx - start_idx, 0))
  end
  defp slice(_, _), do: []

  defp splice(list, [start | rest]) when is_list(list) do
    s = Runtime.normalize_index(start, length(list))
    {delete_count, items} = case rest do
      [] -> {length(list) - s, []}
      [dc | items] -> {max(min(Runtime.to_int(dc), length(list) - s), 0), items}
    end
    {removed, _remaining} = Enum.split(list, s)
    {removed_head, _} = Enum.split(removed, delete_count)
    removed_head
  end
  defp splice(list, _), do: list

  # ── Transform ──

  defp join({:obj, ref}, args), do: join(Process.get({:qb_obj, ref}, []), args)
  defp join(list, [sep | _]) when is_list(list), do: Enum.map_join(list, to_string(sep), &Runtime.js_to_string/1)
  defp join(list, []) when is_list(list), do: Enum.map_join(list, ",", &Runtime.js_to_string/1)
  defp join(_, _), do: ""

  defp concat({:obj, ref}, args) do
    list = Process.get({:qb_obj, ref}, [])
    result = Enum.reduce(args, list, &concat_item(&1, &2))
    new_ref = System.unique_integer([:positive])
    Process.put({:qb_obj, new_ref}, result)
    {:obj, new_ref}
  end
  defp concat(list, args) when is_list(list), do: Enum.reduce(args, list, &concat_item(&1, &2))

  defp concat_item({:obj, r}, acc), do: acc ++ Process.get({:qb_obj, r}, [])
  defp concat_item(a, acc) when is_list(a), do: acc ++ a
  defp concat_item(val, acc), do: acc ++ [val]

  defp reverse({:obj, ref}, _) do
    list = Process.get({:qb_obj, ref}, [])
    Process.put({:qb_obj, ref}, Enum.reverse(list))
    {:obj, ref}
  end
  defp reverse(list, _) when is_list(list), do: Enum.reverse(list)
  defp reverse(_, _), do: []

  defp sort({:obj, ref}, _) do
    list = Process.get({:qb_obj, ref}, [])
    Process.put({:qb_obj, ref}, Enum.sort(list, fn a, b -> Runtime.js_to_string(a) < Runtime.js_to_string(b) end))
    {:obj, ref}
  end
  defp sort(list, _) when is_list(list), do: Enum.sort(list)

  defp flat({:obj, ref}, args), do: flat(Process.get({:qb_obj, ref}, []), args)
  defp flat(list, _) when is_list(list) do
    Enum.flat_map(list, fn
      a when is_list(a) -> a
      val -> [val]
    end)
  end
  defp flat(_, _), do: []

  # ── Predicates ──

  defp find({:obj, ref}, args, interp), do: find(Process.get({:qb_obj, ref}, []), args, interp)
  defp find(list, [fun | _], interp) when is_list(list) do
    Enum.find_value(Enum.with_index(list), :undefined, fn {val, idx} ->
      if Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp)), do: val
    end)
  end
  defp find(_, _, _), do: :undefined

  defp find_index({:obj, ref}, args, interp), do: find_index(Process.get({:qb_obj, ref}, []), args, interp)
  defp find_index(list, [fun | _], interp) when is_list(list) do
    Enum.find_value(Enum.with_index(list), -1, fn {val, idx} ->
      if Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp)), do: idx
    end)
  end
  defp find_index(_, _, _), do: -1

  defp every({:obj, ref}, args, interp), do: every(Process.get({:qb_obj, ref}, []), args, interp)
  defp every(list, [fun | _], interp) when is_list(list) do
    Enum.all?(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end)
  end
  defp every(_, _, _), do: true

  defp some({:obj, ref}, args, interp), do: some(Process.get({:qb_obj, ref}, []), args, interp)
  defp some(list, [fun | _], interp) when is_list(list) do
    Enum.any?(Enum.with_index(list), fn {val, idx} ->
      Runtime.js_truthy(Runtime.call_builtin_callback(fun, [val, idx, list], interp))
    end)
  end
  defp some(_, _, _), do: false

  # ── Array.from ──

  defp from([{:obj, ref} | _]) do
    map = Process.get({:qb_obj, ref}, %{})
    len = Map.get(map, "length", 0)
    for i <- 0..(len - 1), do: Map.get(map, Integer.to_string(i), :undefined)
  end
  defp from([list | _]) when is_list(list), do: list
  defp from([s | _]) when is_binary(s), do: String.graphemes(s)
  defp from(_), do: []

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
