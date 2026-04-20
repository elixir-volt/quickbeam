defmodule QuickBEAM.BeamVM.Heap do
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

  import QuickBEAM.BeamVM.Heap.Keys

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
            obj_is_array?: 1,
            obj_to_list: 1,
            array_get: 2,
            array_size: 1,
            array_push: 2,
            array_set: 3,
            make_error: 2,
            get_object_prototype: 0,
            get_atoms: 0,
            get_persistent_globals: 0}

  # ── Convenience constructors ──

  def wrap(data) do
    ref = make_ref()
    # put_obj handles list -> :qb_arr conversion
    put_obj(ref, data)
    {:obj, ref}
  end

  def to_list({:obj, ref}) do
    case Process.get({:qb_obj, ref}, []) do
      {:qb_arr, arr} ->
        :array.to_list(arr)

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

  def to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def to_list(list) when is_list(list), do: list
  def to_list(_), do: []

  def make_error(message, name) do
    proto =
      case find_error_proto(name) do
        nil -> nil
        ctor -> get_class_proto(ctor)
      end

    base = %{"message" => message, "name" => name, "stack" => ""}
    error = if proto, do: wrap(Map.put(base, "__proto__", proto)), else: wrap(base)

    if get_ctx() != nil,
      do: QuickBEAM.BeamVM.Stacktrace.attach_stack(error),
      else: error
  end

  defp find_error_proto(name) do
    case get_global_cache() do
      nil ->
        case get_ctx() do
          %{globals: globals} -> Map.get(globals, name)
          _ -> nil
        end

      cache ->
        Map.get(cache, name)
    end
  end

  def get_or_create_prototype(ctor) do
    case get_class_proto(ctor) do
      nil ->
        key = {:qb_func_proto, :erlang.phash2(ctor)}

        case Process.get(key) do
          nil ->
            proto = wrap(%{"constructor" => ctor})
            Process.put(key, proto)
            proto

          existing ->
            existing
        end

      proto ->
        proto
    end
  end

  # ── Objects ──

  def get_obj(ref), do: Process.get({:qb_obj, ref})
  def get_obj(ref, default), do: Process.get({:qb_obj, ref}, default)

  def put_obj(ref, list) when is_list(list) do
    Process.put({:qb_obj, ref}, {:qb_arr, :array.from_list(list, :undefined)})
    track_alloc()
  end

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

  # ── Array helpers ──

  def obj_is_array?(ref) do
    case Process.get({:qb_obj, ref}) do
      {:qb_arr, _} -> true
      _ -> false
    end
  end

  def obj_to_list(ref) do
    case Process.get({:qb_obj, ref}) do
      {:qb_arr, arr} -> :array.to_list(arr)
      list when is_list(list) -> list
      _ -> []
    end
  end

  def array_get(ref, idx) do
    case Process.get({:qb_obj, ref}) do
      {:qb_arr, arr} when idx >= 0 ->
        if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined

      _ ->
        :undefined
    end
  end

  def array_size(ref) do
    case Process.get({:qb_obj, ref}) do
      {:qb_arr, arr} -> :array.size(arr)
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  def array_push(ref, values) do
    case Process.get({:qb_obj, ref}) do
      {:qb_arr, arr} ->
        new_arr =
          Enum.reduce(values, {:array.size(arr), arr}, fn v, {i, a} ->
            {i + 1, :array.set(i, v, a)}
          end)
          |> elem(1)

        Process.put({:qb_obj, ref}, {:qb_arr, new_arr})
        :array.size(new_arr)

      _ ->
        0
    end
  end

  def array_set(ref, idx, val) do
    case Process.get({:qb_obj, ref}) do
      {:qb_arr, arr} ->
        Process.put({:qb_obj, ref}, {:qb_arr, :array.set(idx, val, arr)})

      _ ->
        :ok
    end
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

  # ── Interpreter context ──

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

  # ── Singleton state ──

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

  # ── Promise waiters ──

  def get_promise_waiters(ref), do: Process.get({:qb_promise_waiters, ref}, [])
  def put_promise_waiters(ref, waiters), do: Process.put({:qb_promise_waiters, ref}, waiters)
  def delete_promise_waiters(ref), do: Process.delete({:qb_promise_waiters, ref})

  # ── Module registry ──

  def register_module(name, exports) do
    Process.put({:qb_module, name}, exports)
    existing = Process.get(:qb_module_list, [])
    unless name in existing, do: Process.put(:qb_module_list, [name | existing])
  end

  def get_module(name), do: Process.get({:qb_module, name})

  def all_module_exports do
    Process.get(:qb_module_list, [])
    |> Enum.map(&Process.get({:qb_module, &1}))
    |> Enum.reject(&is_nil/1)
  end

  # ── Symbol registry ──

  def get_symbol(key), do: Process.get({:qb_symbol_registry, key})
  def put_symbol(key, sym), do: Process.put({:qb_symbol_registry, key}, sym)

  # ── Garbage collection ──

  @gc_initial_threshold 5_000

  defp track_alloc do
    count = Process.get(:qb_alloc_count, 0) + 1
    Process.put(:qb_alloc_count, count)

    if count >= Process.get(:qb_gc_threshold, @gc_initial_threshold) do
      Process.put(:qb_gc_needed, true)
    end
  end

  def gc_needed?, do: Process.get(:qb_gc_needed, false)

  def mark_and_sweep(roots) do
    marked = mark(roots, MapSet.new())
    sweep_heap(marked)
    live_count = MapSet.size(marked)
    Process.put(:qb_alloc_count, live_count)
    Process.put(:qb_gc_threshold, live_count + max(live_count, @gc_initial_threshold))
    Process.delete(:qb_gc_needed)
  end

  @doc "Clear all heap state. Used in test setup."
  def reset do
    for key <- Process.get_keys() do
      case key do
        {:qb_obj, _} -> Process.delete(key)
        {:qb_cell, _} -> Process.delete(key)
        {:qb_class_proto, _} -> Process.delete(key)
        {:qb_func_proto, _} -> Process.delete(key)
        {:qb_decoded, _} -> Process.delete(key)
        {:qb_promise_waiters, _} -> Process.delete(key)
        {:qb_module, _} -> Process.delete(key)
        {:qb_prop_desc, _, _} -> Process.delete(key)
        {:qb_frozen, _} -> Process.delete(key)
        {:qb_var, _} -> Process.delete(key)
        {:qb_key_order, _} -> Process.delete(key)
        {:qb_runtime_mode, _} -> Process.delete(key)
        {:qb_alloc_count, _} -> Process.delete(key)
        {:qb_gc_threshold, _} -> Process.delete(key)
        {:qb_symbol_registry, _} -> Process.delete(key)
        {:qb_ctor_statics, _} -> Process.delete(key)
        {:qb_parent_ctor, _} -> Process.delete(key)
        :qb_persistent_globals -> Process.delete(key)
        :qb_handler_globals -> Process.delete(key)
        :qb_atoms -> Process.delete(key)
        :qb_module_list -> Process.delete(key)
        :qb_ctx -> Process.delete(key)
        :qb_gc_needed -> Process.delete(key)
        :qb_alloc_count -> Process.delete(key)
        :qb_object_prototype -> Process.delete(key)
        :qb_global_bindings_cache -> Process.delete(key)
        :qb_microtask_queue -> Process.delete(key)
        _ -> :ok
      end
    end

    :ok
  end

  @doc "Full GC between independent eval() invocations."
  def gc do
    module_roots = all_module_exports()
    persistent_roots = get_persistent_globals() |> Map.values()
    all_roots = module_roots ++ persistent_roots

    marked = if all_roots == [], do: nil, else: mark(all_roots, MapSet.new())
    sweep_all(marked)
  end

  # ── Mark phase ──

  defp mark([], visited), do: visited

  defp mark([{:obj, ref} | rest], visited) do
    mark_ref({:qb_obj, ref}, rest, visited, fn
      map when is_map(map) -> Map.values(map) ++ Map.keys(map)
      {:qb_arr, arr} -> :array.to_list(arr)
      list when is_list(list) -> list
      _ -> []
    end)
  end

  defp mark([{:cell, ref} | rest], visited) do
    mark_ref({:qb_cell, ref}, rest, visited, fn val -> [val] end)
  end

  defp mark([{:closure, captured, %QuickBEAM.BeamVM.Bytecode.Function{} = fun} = closure | rest], visited) do
    related = [get_class_proto(closure), get_class_proto(fun), get_parent_ctor(fun)]
    statics = Map.values(get_ctor_statics(closure)) ++ Map.values(get_ctor_statics(fun))
    mark(Map.values(captured) ++ related ++ statics ++ rest, visited)
  end

  defp mark([{:builtin, _, _} = builtin | rest], visited) do
    related = [get_class_proto(builtin), get_parent_ctor(builtin)]
    statics = Map.values(get_ctor_statics(builtin))
    mark(related ++ statics ++ rest, visited)
  end

  defp mark([%QuickBEAM.BeamVM.Bytecode.Function{} = fun | rest], visited) do
    related = [get_class_proto(fun), get_parent_ctor(fun)]
    statics = Map.values(get_ctor_statics(fun))
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

  defp heap_key?({:qb_obj, _}), do: true
  defp heap_key?({:qb_cell, _}), do: true
  defp heap_key?(_), do: false

  defp ephemeral_key?({:qb_prop_desc, _, _}), do: true
  defp ephemeral_key?({:qb_frozen, _}), do: true
  defp ephemeral_key?({:qb_var, _}), do: true
  defp ephemeral_key?({:qb_key_order, _}), do: true
  defp ephemeral_key?(_), do: false
end
