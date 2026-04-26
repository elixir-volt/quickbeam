defmodule QuickBEAM.VM.Heap.GC do
  @moduledoc "Mark-and-sweep garbage collector for the JS object heap."

  alias QuickBEAM.VM.Heap.{Context, Registry, Store}

  @gc_initial_threshold 5_000
  @doc "Returns the allocation threshold that triggers the first heap GC pass."
  def gc_initial_threshold, do: @gc_initial_threshold

  def gc_needed?, do: Process.get(:qb_gc_needed, false)

  def mark_and_sweep(roots) do
    marked = mark(roots, MapSet.new())
    sweep_heap(marked)
    live_count = MapSet.size(marked)
    Process.put(:qb_alloc_count, live_count)
    Process.put(:qb_gc_threshold, live_count + max(live_count, @gc_initial_threshold))
    Process.delete(:qb_gc_needed)
  end

  @doc "Helper for mark-and-sweep garbage collector for the js object heap."
  def gc(extra_roots \\ []) do
    module_roots = Registry.all_module_exports()
    persistent_roots = Context.get_persistent_globals() |> Map.values()
    all_roots = List.wrap(extra_roots) ++ module_roots ++ persistent_roots

    marked = if all_roots == [], do: nil, else: mark(all_roots, MapSet.new())
    sweep_all(marked)
  end

  # ── Mark phase ──

  defp mark([], visited), do: visited

  defp mark([{:obj, ref} | rest], visited) do
    mark_ref(ref, rest, visited, fn
      {:shape, _shape_id, _offsets, vals, proto} ->
        Tuple.to_list(vals) ++ [proto]

      map when is_map(map) ->
        Map.values(map) ++ Map.keys(map)

      {:qb_arr, arr} ->
        :array.to_list(arr)

      list when is_list(list) ->
        list

      _ ->
        []
    end)
  end

  defp mark([{:cell, ref} | rest], visited) do
    mark_ref({:qb_cell, ref}, rest, visited, fn val -> [val] end)
  end

  defp mark(
         [{:closure, captured, %QuickBEAM.VM.Bytecode.Function{} = fun} = closure | rest],
         visited
       ) do
    related = [
      Store.get_class_proto(closure),
      Store.get_class_proto(fun),
      Store.get_parent_ctor(fun)
    ]

    statics =
      Map.values(Store.get_ctor_statics(closure)) ++ Map.values(Store.get_ctor_statics(fun))

    mark(Map.values(captured) ++ related ++ statics ++ rest, visited)
  end

  defp mark([{:builtin, _, _} = builtin | rest], visited) do
    related = [Store.get_class_proto(builtin), Store.get_parent_ctor(builtin)]
    statics = Map.values(Store.get_ctor_statics(builtin))
    mark(related ++ statics ++ rest, visited)
  end

  defp mark([%QuickBEAM.VM.Bytecode.Function{} = fun | rest], visited) do
    related = [Store.get_class_proto(fun), Store.get_parent_ctor(fun)]
    statics = Map.values(Store.get_ctor_statics(fun))
    mark(Map.values(Map.from_struct(fun)) ++ related ++ statics ++ rest, visited)
  end

  defp mark([tuple | rest], visited) when is_tuple(tuple),
    do: mark(Tuple.to_list(tuple) ++ rest, visited)

  defp mark([list | rest], visited) when is_list(list),
    do: mark(list ++ rest, visited)

  defp mark([%{} = map | rest], visited),
    do: mark(Map.values(map) ++ rest, visited)

  defp mark([_ | rest], visited), do: mark(rest, visited)

  defp mark_ref(key, rest, visited, children_fn) do
    if MapSet.member?(visited, key) do
      mark(rest, visited)
    else
      visited = MapSet.put(visited, key)
      children = children_fn.(Process.get(key, :undefined))
      mark(children ++ rest, visited)
    end
  end

  # ── Sweep phase ──

  defp sweep_heap(marked) do
    for key <- Process.get_keys(), heap_key?(key), not MapSet.member?(marked, key) do
      Process.delete(key)
    end
  end

  defp sweep_all(marked) do
    for key <- Process.get_keys() do
      cond do
        heap_key?(key) -> unless marked && MapSet.member?(marked, key), do: Process.delete(key)
        ephemeral_key?(key) -> Process.delete(key)
        true -> :ok
      end
    end
  end

  defp heap_key?(key) when is_integer(key) and key > 0, do: true
  defp heap_key?({:qb_cell, _}), do: true
  defp heap_key?(_), do: false

  defp ephemeral_key?({:qb_prop_desc, _, _}), do: true
  defp ephemeral_key?({:qb_frozen, _}), do: true
  defp ephemeral_key?({:qb_var, _}), do: true
  defp ephemeral_key?({:qb_key_order, _}), do: true
  defp ephemeral_key?(_), do: false
end
