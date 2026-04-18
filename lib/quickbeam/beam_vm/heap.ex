defmodule QuickBEAM.BeamVM.Heap do
  @compile {:inline,
            get_obj: 1,
            get_obj: 2,
            put_obj: 2,
            update_obj: 3,
            get_cell: 1,
            put_cell: 2,
            get_var: 1,
            put_var: 2,
            delete_var: 1,
            get_ctx: 0,
            put_ctx: 1,
            frozen?: 1,
            freeze: 1,
            get_decoded: 1,
            put_decoded: 2,
            get_class_proto: 1,
            put_class_proto: 2,
            get_parent_ctor: 1,
            put_parent_ctor: 2,
            get_ctor_statics: 1}
  @moduledoc """
  Mutable heap storage for JS runtime values.

  All heap access goes through this module — callers never touch
  the process dictionary directly. Current implementation uses the
  process dictionary for single-process performance; the backing
  store can be swapped to ETS for concurrent access.

  ## Storage keys
    - `{:qb_obj, ref}` — JS object/array properties
    - `{:qb_cell, ref}` — closure variable cells
    - `{:qb_class_proto, hash}` — class prototype objects
    - `{:qb_parent_ctor, hash}` — parent constructor references
    - `{:qb_var, name}` — global variable bindings
  """

  # ── Objects ──

  def get_obj(ref), do: Process.get({:qb_obj, ref})
  def get_obj(ref, default), do: Process.get({:qb_obj, ref}, default)

  def put_obj(ref, val) do
    Process.put({:qb_obj, ref}, val)
    track_alloc()
  end

  def put_obj_key(ref, key, val) do
    map = get_obj(ref, %{})

    if is_map(map) do
      new_map =
        if not Map.has_key?(map, key) and (is_binary(key) or is_integer(key)) do
          order = Map.get(map, :__key_order__, [])
          Map.put(Map.put(map, key, val), :__key_order__, [key | order])
        else
          Map.put(map, key, val)
        end

      Process.put({:qb_obj, ref}, new_map)
    else
      Process.put({:qb_obj, ref}, val)
    end
  end

  def update_obj(ref, default, fun) do
    Process.put({:qb_obj, ref}, fun.(Process.get({:qb_obj, ref}, default)))
  end

  # ── Closure cells ──

  def get_cell(ref), do: Process.get({:qb_cell, ref}, :undefined)
  def put_cell(ref, val), do: Process.put({:qb_cell, ref}, val)

  # ── Class metadata ──

  def get_class_proto({:closure, _, raw} = ctor) do
    Process.get({:qb_class_proto, :erlang.phash2(ctor)}) ||
      Process.get({:qb_class_proto, :erlang.phash2(raw)})
  end

  def get_class_proto(ctor), do: Process.get({:qb_class_proto, :erlang.phash2(ctor)})

  def put_class_proto(ctor, proto),
    do: Process.put({:qb_class_proto, :erlang.phash2(ctor)}, proto)

  def get_parent_ctor({:closure, _, raw} = ctor) do
    Process.get({:qb_parent_ctor, :erlang.phash2(ctor)}) ||
      Process.get({:qb_parent_ctor, :erlang.phash2(raw)})
  end

  def get_parent_ctor(ctor), do: Process.get({:qb_parent_ctor, :erlang.phash2(ctor)})

  def put_parent_ctor(ctor, parent),
    do: Process.put({:qb_parent_ctor, :erlang.phash2(ctor)}, parent)

  # ── Constructor statics ──

  def get_ctor_statics(ctor), do: Process.get({:qb_ctor_statics, :erlang.phash2(ctor)}, %{})

  def put_ctor_static(ctor, key, val) do
    statics = get_ctor_statics(ctor)
    Process.put({:qb_ctor_statics, :erlang.phash2(ctor)}, Map.put(statics, key, val))
  end

  # ── Variable bindings ──

  def get_var(name), do: Process.get({:qb_var, name})
  def put_var(name, val), do: Process.put({:qb_var, name}, val)
  def delete_var(name), do: Process.delete({:qb_var, name})

  # ── Active interpreter context ──

  def get_ctx, do: Process.get(:qb_ctx)
  def put_ctx(ctx), do: Process.put(:qb_ctx, ctx)

  # ── Bytecode decode cache ──

  def get_decoded(byte_code), do: Process.get({:qb_decoded, byte_code})
  def put_decoded(byte_code, insns), do: Process.put({:qb_decoded, byte_code}, insns)

  # ── Frozen objects ──

  def frozen?(ref), do: Process.get({:qb_frozen, ref}, false)
  def freeze(ref), do: Process.put({:qb_frozen, ref}, true)

  # ── Property descriptors ──

  def get_prop_desc(ref, key), do: Process.get({:qb_prop_desc, ref, key})
  def put_prop_desc(ref, key, desc), do: Process.put({:qb_prop_desc, ref, key}, desc)

  # ── GC: pressure-triggered mark-sweep ──

  @gc_initial_threshold 5_000

  def track_alloc do
    count = Process.get(:qb_alloc_count, 0) + 1
    Process.put(:qb_alloc_count, count)
    threshold = Process.get(:qb_gc_threshold, @gc_initial_threshold)

    if count >= threshold do
      # Signal that GC is needed — actual collection happens at a safe point
      Process.put(:qb_gc_needed, true)
    end
  end

  def gc_needed?, do: Process.get(:qb_gc_needed, false)

  def mark_and_sweep(roots) do
    marked = mark(roots, MapSet.new())
    sweep(marked)
    live_count = MapSet.size(marked)
    Process.put(:qb_alloc_count, live_count)
    Process.put(:qb_gc_threshold, live_count + max(live_count, @gc_initial_threshold))
    Process.delete(:qb_gc_needed)
  end

  defp mark([], visited), do: visited

  defp mark([{:obj, ref} | rest], visited) do
    key = {:qb_obj, ref}

    if MapSet.member?(visited, key) do
      mark(rest, visited)
    else
      visited = MapSet.put(visited, key)

      case Process.get(key) do
        map when is_map(map) ->
          children = Map.values(map) ++ Map.keys(map)
          mark(children ++ rest, visited)

        list when is_list(list) ->
          mark(list ++ rest, visited)

        _ ->
          mark(rest, visited)
      end
    end
  end

  defp mark([{:cell, ref} | rest], visited) do
    key = {:qb_cell, ref}

    if MapSet.member?(visited, key) do
      mark(rest, visited)
    else
      visited = MapSet.put(visited, key)
      val = Process.get(key, :undefined)
      mark([val | rest], visited)
    end
  end

  defp mark([{:closure, captured, _fun} | rest], visited) do
    cells = Map.values(captured)
    mark(cells ++ rest, visited)
  end

  defp mark([tuple | rest], visited) when is_tuple(tuple) do
    mark(Tuple.to_list(tuple) ++ rest, visited)
  end

  defp mark([list | rest], visited) when is_list(list) do
    mark(list ++ rest, visited)
  end

  defp mark([%{} = map | rest], visited) do
    mark(Map.values(map) ++ rest, visited)
  end

  defp mark([_ | rest], visited), do: mark(rest, visited)

  defp sweep(marked) do
    Process.get_keys()
    |> Enum.each(fn
      {:qb_obj, _} = k -> unless MapSet.member?(marked, k), do: Process.delete(k)
      {:qb_cell, _} = k -> unless MapSet.member?(marked, k), do: Process.delete(k)
      _ -> :ok
    end)
  end

  # ── Microtask queue ──

  def enqueue_microtask(task) do
    queue = Process.get(:qb_microtask_queue, :queue.new())
    Process.put(:qb_microtask_queue, :queue.in(task, queue))
  end

  def dequeue_microtask do
    queue = Process.get(:qb_microtask_queue, :queue.new())

    case :queue.out(queue) do
      {{:value, task}, rest} ->
        Process.put(:qb_microtask_queue, rest)
        task

      {:empty, _} ->
        nil
    end
  end

  def microtask_queue_empty? do
    queue = Process.get(:qb_microtask_queue, :queue.new())
    :queue.is_empty(queue)
  end

  # ── Module registry ──

  def register_module(name, exports) do
    Process.put({:qb_module, name}, exports)
  end

  def all_module_exports do
    Process.get_keys()
    |> Enum.filter(fn
      {:qb_module, _} -> true
      _ -> false
    end)
    |> Enum.map(fn k -> Process.get(k) end)
  end

  def get_module(name) do
    Process.get({:qb_module, name})
  end

  # ── GC ──

  @doc "Delete all heap data. Call between independent eval() invocations to free memory."
  def gc do
    # Collect module exports as roots to preserve
    module_roots = all_module_exports()

    if module_roots == [] do
      # Fast path: no modules, delete everything
      Process.get_keys()
      |> Enum.each(fn
        {:qb_obj, _} = k -> Process.delete(k)
        {:qb_cell, _} = k -> Process.delete(k)
        {:qb_class_proto, _} = k -> Process.delete(k)
        {:qb_parent_ctor, _} = k -> Process.delete(k)
        {:qb_ctor_statics, _} = k -> Process.delete(k)
        {:qb_prop_desc, _, _} = k -> Process.delete(k)
        {:qb_frozen, _} = k -> Process.delete(k)
        {:qb_var, _} = k -> Process.delete(k)
        {:qb_key_order, _} = k -> Process.delete(k)
        _ -> :ok
      end)
    else
      # Mark module-reachable objects, sweep the rest
      marked = mark(module_roots, MapSet.new())

      Process.get_keys()
      |> Enum.each(fn
        {:qb_obj, _} = k -> unless MapSet.member?(marked, k), do: Process.delete(k)
        {:qb_cell, _} = k -> unless MapSet.member?(marked, k), do: Process.delete(k)
        {:qb_class_proto, _} = k -> Process.delete(k)
        {:qb_parent_ctor, _} = k -> Process.delete(k)
        {:qb_ctor_statics, _} = k -> Process.delete(k)
        {:qb_prop_desc, _, _} = k -> Process.delete(k)
        {:qb_frozen, _} = k -> Process.delete(k)
        {:qb_var, _} = k -> Process.delete(k)
        {:qb_key_order, _} = k -> Process.delete(k)
        _ -> :ok
      end)
    end
  end

  # ── Symbol registry ──

  def get_symbol(key), do: Process.get({:qb_symbol_registry, key})
  def put_symbol(key, sym), do: Process.put({:qb_symbol_registry, key}, sym)
end
