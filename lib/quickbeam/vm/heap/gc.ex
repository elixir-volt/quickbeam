defmodule QuickBEAM.VM.Heap.GC do
  @moduledoc "Mark-and-sweep garbage collector for the JS object heap."

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.Heap.{Context, Registry, Store}

  @gc_initial_threshold 200_000
  @doc "Returns the allocation threshold that triggers the first heap GC pass."
  def gc_initial_threshold, do: @gc_initial_threshold

  def gc_needed?, do: Process.get(:qb_gc_needed, false)

  def mark_and_sweep(roots) do
    marked = mark(List.wrap(roots) ++ temp_roots(), MapSet.new())
    sweep(marked)
    reset_gc_accounting(marked)
  end

  def with_temp_roots(roots, fun) when is_function(fun, 0) do
    previous_roots = temp_roots()
    Process.put(:qb_temp_roots, List.wrap(roots) ++ previous_roots)

    try do
      fun.()
    after
      case previous_roots do
        [] -> Process.delete(:qb_temp_roots)
        _ -> Process.put(:qb_temp_roots, previous_roots)
      end
    end
  end

  def temp_roots, do: Process.get(:qb_temp_roots, [])

  @doc "Helper for mark-and-sweep garbage collector for the js object heap."
  def gc(extra_roots \\ []) do
    module_roots = Registry.all_module_exports()
    persistent_roots = Context.get_persistent_globals() |> Map.values()

    all_roots =
      List.wrap(extra_roots) ++
        module_roots ++ persistent_roots ++ temp_roots() ++ process_cache_roots()

    marked = mark(all_roots, MapSet.new())
    sweep(marked)
    reset_gc_accounting(marked)
  end

  # ── Mark phase ──

  defp mark([], visited), do: visited

  defp mark([{:obj, ref} | rest], visited) do
    mark_ref(ref, rest, visited, fn
      {:shape, _shape_id, _offsets, vals, proto} ->
        Tuple.to_list(vals) ++ [proto] ++ object_side_children(ref)

      map when is_map(map) ->
        Map.values(map) ++ Map.keys(map) ++ object_side_children(ref)

      {:qb_arr, arr} ->
        :array.sparse_to_list(arr) ++ object_side_children(ref)

      list when is_list(list) ->
        list ++ object_side_children(ref)

      _ ->
        object_side_children(ref)
    end)
  end

  defp mark([{:cell, ref} | rest], visited) do
    mark_ref({:qb_cell, ref}, rest, visited, fn val -> [val] end)
  end

  defp mark(
         [{:closure, captured, %QuickBEAM.VM.Function{} = fun} = closure | rest],
         visited
       ) do
    mark_callable({:closure, :erlang.phash2(closure)}, rest, visited, fn ->
      related = [
        Store.get_class_proto(closure),
        Store.get_class_proto(fun),
        Store.get_parent_ctor(fun)
      ]

      statics =
        Map.values(Store.get_ctor_statics(closure)) ++ Map.values(Store.get_ctor_statics(fun))

      Map.values(captured) ++
        related ++
        statics ++
        callable_side_children(closure) ++
        callable_side_children(fun)
    end)
  end

  defp mark([{:builtin, _, _} = builtin | rest], visited) do
    mark_callable({:builtin, :erlang.phash2(builtin)}, rest, visited, fn ->
      related = [Store.get_class_proto(builtin), Store.get_parent_ctor(builtin)]
      statics = Map.values(Store.get_ctor_statics(builtin))
      related ++ statics ++ callable_side_children(builtin)
    end)
  end

  defp mark([{:regexp, _bytecode, _source, ref} = regexp | rest], visited) do
    mark_ref(RegexpState.key(ref), regexp_tuple_children(regexp) ++ rest, visited, fn props ->
      case props do
        map when is_map(map) -> Map.values(map) ++ Map.keys(map)
        _ -> []
      end
    end)
  end

  defp mark([%QuickBEAM.VM.Function{} = fun | rest], visited) do
    mark_callable({:function, fun.id}, rest, visited, fn ->
      related = [Store.get_class_proto(fun), Store.get_parent_ctor(fun)]
      statics = Map.values(Store.get_ctor_statics(fun))
      Map.values(Map.from_struct(fun)) ++ related ++ statics ++ callable_side_children(fun)
    end)
  end

  defp mark([tuple | rest], visited) when is_tuple(tuple),
    do: mark(Tuple.to_list(tuple) ++ rest, visited)

  defp mark([list | rest], visited) when is_list(list),
    do: mark(list ++ rest, visited)

  defp mark([%{} = map | rest], visited),
    do: mark(Map.values(map) ++ rest, visited)

  defp mark([_ | rest], visited), do: mark(rest, visited)

  defp mark_callable(key, rest, visited, children_fn) do
    if MapSet.member?(visited, key) do
      mark(rest, visited)
    else
      visited = MapSet.put(visited, key)
      mark(children_fn.() ++ rest, visited)
    end
  end

  defp regexp_tuple_children({:regexp, bytecode, source, _ref}), do: [bytecode, source]

  defp mark_ref(key, rest, visited, children_fn) do
    if MapSet.member?(visited, key) do
      mark(rest, visited)
    else
      visited = MapSet.put(visited, key)
      children = children_fn.(Process.get(key, :undefined))
      mark(children ++ rest, visited)
    end
  end

  defp object_side_children(ref) do
    Process.get({:qb_array_props, ref}, %{})
    |> Map.values()
    |> Kernel.++(descriptor_values(ref))
  end

  defp descriptor_values(ref) do
    ref
    |> Store.prop_desc_values()
    |> Enum.flat_map(fn
      desc when is_map(desc) -> Map.values(desc)
      value -> [value]
    end)
  end

  defp process_cache_roots do
    Process.get_keys()
    |> Enum.reject(&heap_storage_key?/1)
    |> Enum.filter(&quickbeam_cache_key?/1)
    |> Enum.map(&Process.get/1)
  end

  defp heap_storage_key?(key),
    do: heap_key?(key) or regexp_state_key?(key) or owner_side_table_key?(key)

  defp quickbeam_cache_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.starts_with?("qb_")

  defp quickbeam_cache_key?(key) when is_tuple(key) and tuple_size(key) > 0 do
    key
    |> elem(0)
    |> quickbeam_cache_key?()
  end

  defp quickbeam_cache_key?(_), do: false

  defp callable_side_children(callable) do
    callable
    |> ctor_key()
    |> Store.ctor_prop_desc_values()
    |> Enum.flat_map(fn
      desc when is_map(desc) -> Map.values(desc)
      value -> [value]
    end)
  end

  # ── Sweep phase ──

  defp sweep(marked) do
    for key <- Process.get_keys() do
      cond do
        heap_key?(key) or regexp_state_key?(key) ->
          unless MapSet.member?(marked, key), do: Process.delete(key)

        owner_side_table_key?(key) ->
          unless side_table_owner_marked?(key, marked), do: Process.delete(key)

        true ->
          :ok
      end
    end
  end

  defp reset_gc_accounting(marked) do
    live_count = MapSet.size(marked)
    Process.put(:qb_alloc_count, live_count)
    Process.put(:qb_gc_threshold, live_count + max(live_count, @gc_initial_threshold))
    Process.delete(:qb_gc_needed)
  end

  defp heap_key?(key) when is_integer(key) and key > 0, do: true
  defp heap_key?({:qb_cell, _}), do: true
  defp heap_key?(_), do: false

  defp regexp_state_key?(key), do: RegexpState.key?(key)

  defp owner_side_table_key?({:qb_prop_desc, _, _}), do: true
  defp owner_side_table_key?({:qb_prop_desc_index, _}), do: true
  defp owner_side_table_key?({:qb_array_props, _}), do: true
  defp owner_side_table_key?({:qb_frozen, _}), do: true
  defp owner_side_table_key?({:qb_non_extensible, _}), do: true
  defp owner_side_table_key?({:qb_key_order, _}), do: true
  defp owner_side_table_key?({:qb_ctor_prop_desc, _, _}), do: true
  defp owner_side_table_key?({:qb_ctor_prop_desc_index, _}), do: true
  defp owner_side_table_key?({:qb_ctor_statics, _}), do: true
  defp owner_side_table_key?({:qb_class_proto, _}), do: true
  defp owner_side_table_key?({:qb_parent_ctor, _}), do: true
  defp owner_side_table_key?(_), do: false

  defp side_table_owner_marked?({:qb_prop_desc, ref, _}, marked), do: MapSet.member?(marked, ref)

  defp side_table_owner_marked?({:qb_prop_desc_index, ref}, marked),
    do: MapSet.member?(marked, ref)

  defp side_table_owner_marked?({:qb_array_props, ref}, marked), do: MapSet.member?(marked, ref)
  defp side_table_owner_marked?({:qb_frozen, ref}, marked), do: MapSet.member?(marked, ref)

  defp side_table_owner_marked?({:qb_non_extensible, ref}, marked),
    do: MapSet.member?(marked, ref)

  defp side_table_owner_marked?({:qb_key_order, ref}, marked), do: MapSet.member?(marked, ref)

  defp side_table_owner_marked?({:qb_ctor_prop_desc, owner, _}, marked),
    do: callable_owner_marked?(owner, marked)

  defp side_table_owner_marked?({:qb_ctor_prop_desc_index, owner}, marked),
    do: callable_owner_marked?(owner, marked)

  defp side_table_owner_marked?({:qb_ctor_statics, owner}, marked),
    do: callable_owner_marked?(owner, marked)

  defp side_table_owner_marked?({:qb_class_proto, owner}, marked),
    do: callable_owner_marked?(owner, marked)

  defp side_table_owner_marked?({:qb_parent_ctor, owner}, marked),
    do: callable_owner_marked?(owner, marked)

  defp callable_owner_marked?(owner, marked) do
    MapSet.member?(marked, owner) or MapSet.member?(marked, callable_mark_key(owner))
  end

  defp callable_mark_key({:builtin, _, _} = builtin), do: {:builtin, :erlang.phash2(builtin)}
  defp callable_mark_key({:closure, _, _} = closure), do: {:closure, :erlang.phash2(closure)}
  defp callable_mark_key(%QuickBEAM.VM.Function{id: id}), do: {:function, id}
  defp callable_mark_key(owner), do: owner

  defp ctor_key({:closure, _captured, %QuickBEAM.VM.Function{} = fun}), do: ctor_key(fun)
  defp ctor_key(%QuickBEAM.VM.Function{id: id}) when is_integer(id), do: {:function, id}
  defp ctor_key(%QuickBEAM.VM.Function{} = fun), do: {:function, :erlang.phash2(fun)}
  defp ctor_key(ctor), do: ctor
end
