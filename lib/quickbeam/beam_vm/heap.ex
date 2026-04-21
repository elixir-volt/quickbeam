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
    - `{:qb_class_proto, ctor}` — class prototype objects
    - `{:qb_parent_ctor, ctor}` — parent constructor references
    - `{:qb_var, name}` — global variable bindings
  """

  alias QuickBEAM.BeamVM.Heap.{Async, Caches, Context, Registry, Store}

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
            get_compiled: 1,
            put_compiled: 2,
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
        key = {:qb_func_proto, ctor}

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

  defdelegate get_obj(ref), to: Store
  defdelegate get_obj(ref, default), to: Store
  defdelegate put_obj(ref, value), to: Store
  defdelegate put_obj_key(ref, key, value), to: Store
  defdelegate update_obj(ref, default, fun), to: Store

  # ── Array helpers ──

  defdelegate obj_is_array?(ref), to: Store
  defdelegate obj_to_list(ref), to: Store
  defdelegate array_get(ref, idx), to: Store
  defdelegate array_size(ref), to: Store
  defdelegate array_push(ref, values), to: Store
  defdelegate array_set(ref, idx, value), to: Store

  # ── Closure cells ──

  defdelegate get_cell(ref), to: Store
  defdelegate put_cell(ref, value), to: Store

  # ── Class metadata ──

  defdelegate get_class_proto(ctor), to: Store
  defdelegate put_class_proto(ctor, proto), to: Store
  defdelegate get_parent_ctor(ctor), to: Store
  defdelegate put_parent_ctor(ctor, parent), to: Store
  defdelegate delete_parent_ctor(ctor), to: Store
  defdelegate get_ctor_statics(ctor), to: Store
  defdelegate put_ctor_statics(ctor, statics), to: Store
  defdelegate put_ctor_static(ctor, key, value), to: Store
  defdelegate get_var(name), to: Store
  defdelegate put_var(name, value), to: Store
  defdelegate delete_var(name), to: Store

  # ── Interpreter context ──

  defdelegate get_ctx(), to: Context
  defdelegate put_ctx(ctx), to: Context
  defdelegate get_decoded(byte_code), to: Caches
  defdelegate put_decoded(byte_code, instructions), to: Caches
  defdelegate get_compiled(key), to: Caches
  defdelegate put_compiled(key, compiled), to: Caches
  defdelegate frozen?(ref), to: Store
  defdelegate freeze(ref), to: Store
  defdelegate get_prop_desc(ref, key), to: Store
  defdelegate put_prop_desc(ref, key, desc), to: Store
  defdelegate get_object_prototype(), to: Context
  defdelegate put_object_prototype(proto), to: Context
  defdelegate get_global_cache(), to: Context
  defdelegate put_global_cache(bindings), to: Context
  defdelegate get_atoms(), to: Context
  defdelegate put_atoms(atoms), to: Context
  defdelegate get_persistent_globals(), to: Context
  defdelegate put_persistent_globals(globals), to: Context
  defdelegate get_handler_globals(), to: Context
  defdelegate put_handler_globals(globals), to: Context
  defdelegate get_runtime_mode(runtime), to: Context
  defdelegate put_runtime_mode(runtime, mode), to: Context
  defdelegate enqueue_microtask(task), to: Async
  defdelegate dequeue_microtask(), to: Async
  defdelegate get_promise_waiters(ref), to: Async
  defdelegate put_promise_waiters(ref, waiters), to: Async
  defdelegate delete_promise_waiters(ref), to: Async
  defdelegate register_module(name, exports), to: Registry
  defdelegate get_module(name), to: Registry
  defdelegate all_module_exports(), to: Registry
  defdelegate get_symbol(key), to: Registry
  defdelegate put_symbol(key, sym), to: Registry

  # ── Garbage collection ──

  @gc_initial_threshold 5_000

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
        {:qb_compiled, _} -> Process.delete(key)
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

  defp mark(
         [{:closure, captured, %QuickBEAM.BeamVM.Bytecode.Function{} = fun} = closure | rest],
         visited
       ) do
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
