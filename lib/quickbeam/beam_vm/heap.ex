defmodule QuickBEAM.BeamVM.Heap do
  import QuickBEAM.BeamVM.InternalKeys

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
            get_ctor_statics: 1,
            wrap: 1,
            to_list: 1,
            iter_result: 2,
            make_error: 2,
            get_object_prototype: 0,
            get_atoms: 0,
            get_persistent_globals: 0}
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

  # ── Convenience constructors ──

  def wrap(data) do
    ref = make_ref()
    put_obj(ref, data)
    {:obj, ref}
  end

  def to_list({:obj, ref}) do
    case get_obj(ref, []) do
      list when is_list(list) ->
        list

      map when is_map(map) ->
        len = Map.get(map, "length", 0)

        if is_integer(len) and len > 0,
          do: for(i <- 0..(len - 1), do: Map.get(map, Integer.to_string(i), :undefined)),
          else: []

      _ ->
        []
    end
  end

  def to_list(list) when is_list(list), do: list
  def to_list(_), do: []

  def iter_result(val, done), do: wrap(%{"value" => val, "done" => done})

  def make_error(message, name) do
    base = %{"message" => message, "name" => name, "stack" => ""}

    # Try to find the error constructor's prototype for instanceof chain
    error_ctor =
      case get_global_cache() do
        nil ->
          case get_ctx() do
            %{globals: globals} -> Map.get(globals, name)
            _ -> nil
          end

        cache ->
          Map.get(cache, name)
      end

    proto = if error_ctor, do: get_class_proto(error_ctor), else: nil

    if proto do
      wrap(Map.put(base, "__proto__", proto))
    else
      wrap(base)
    end
  end

  def get_or_create_prototype(ctor) do
    class_proto = get_class_proto(ctor)

    if class_proto do
      class_proto
    else
      key = {:qb_func_proto, :erlang.phash2(ctor)}

      case Process.get(key) do
        nil ->
          proto_ref = make_ref()
          put_obj(proto_ref, %{"constructor" => ctor})
          proto = {:obj, proto_ref}
          Process.put(key, proto)
          proto

        existing ->
          existing
      end
    end
  end

  # ── Singleton PD accessors ──

  def get_object_prototype, do: Process.get(:qb_object_prototype)
  def put_object_prototype(proto), do: Process.put(:qb_object_prototype, proto)

  def get_global_cache, do: Process.get(:qb_global_bindings_cache)
  def put_global_cache(bindings), do: Process.put(:qb_global_bindings_cache, bindings)

  def get_atoms, do: Process.get(:qb_atoms, {})
  def put_atoms(atoms), do: Process.put(:qb_atoms, atoms)

  def get_persistent_globals, do: Process.get(:qb_persistent_globals, %{})
  def put_persistent_globals(globals), do: Process.put(:qb_persistent_globals, globals)

  def get_handler_globals, do: Process.get(:qb_handler_globals)
  def put_handler_globals(globals), do: Process.put(:qb_handler_globals, globals)

  def get_runtime_mode(runtime), do: Process.get({:qb_runtime_mode, runtime})
  def put_runtime_mode(runtime, mode), do: Process.put({:qb_runtime_mode, runtime}, mode)

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
          order = Map.get(map, key_order(), [])

          Map.put(Map.put(map, key, val), key_order(), [key | order])
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
    existing = Process.get(:qb_module_list, [])

    unless name in existing do
      Process.put(:qb_module_list, [name | existing])
    end
  end

  def all_module_exports do
    Process.get(:qb_module_list, [])
    |> Enum.map(fn name -> Process.get({:qb_module, name}) end)
    |> Enum.reject(&is_nil/1)
  end

  def get_module(name) do
    Process.get({:qb_module, name})
  end

  # ── GC ──

  @doc "Delete all heap data. Call between independent eval() invocations to free memory."
  def gc do
    module_roots = all_module_exports()
    persistent_roots = Process.get(:qb_persistent_globals, %{}) |> Map.values()
    all_roots = module_roots ++ persistent_roots

    marked = if all_roots == [], do: nil, else: mark(all_roots, MapSet.new())
    sweep_keys(marked)
  end

  defp sweep_keys(marked) do
    Process.get_keys()
    |> Enum.each(fn
      {:qb_obj, _} = k -> sweep_key(k, marked)
      {:qb_cell, _} = k -> sweep_key(k, marked)
      # {:qb_class_proto, _}, {:qb_parent_ctor, _}, {:qb_ctor_statics, _}
      # are preserved across GC — they're set during global initialization
      {:qb_prop_desc, _, _} = k -> Process.delete(k)
      {:qb_frozen, _} = k -> Process.delete(k)
      {:qb_var, _} = k -> Process.delete(k)
      {:qb_key_order, _} = k -> Process.delete(k)
      _ -> :ok
    end)
  end

  defp sweep_key(key, nil), do: Process.delete(key)
  defp sweep_key(key, marked), do: unless(MapSet.member?(marked, key), do: Process.delete(key))

  # ── Promise waiters ──

  def get_promise_waiters(ref), do: Process.get({:qb_promise_waiters, ref}, [])
  def put_promise_waiters(ref, waiters), do: Process.put({:qb_promise_waiters, ref}, waiters)
  def delete_promise_waiters(ref), do: Process.delete({:qb_promise_waiters, ref})

  # ── Symbol registry ──

  def get_symbol(key), do: Process.get({:qb_symbol_registry, key})
  def put_symbol(key, sym), do: Process.put({:qb_symbol_registry, key}, sym)
end
