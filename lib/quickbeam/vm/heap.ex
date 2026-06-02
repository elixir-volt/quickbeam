defmodule QuickBEAM.VM.Heap do
  @moduledoc """
  Mutable heap storage for JS runtime values.

  All heap access goes through this module — callers never touch
  the process dictionary directly. Current implementation uses the
  process dictionary for single-process performance; the backing
  store can be swapped to ETS for concurrent access.

  ## Storage keys

    - `integer_id` — JS object/array properties (raw integer keys)
    - `{:qb_cell, ref}` — closure variable cells
    - `{:qb_class_proto, ctor}` — class prototype objects
    - `{:qb_parent_ctor, ctor}` — parent constructor references
    - `{:qb_var, name}` — global variable bindings
  """

  alias QuickBEAM.VM.Execution.IteratorState

  alias QuickBEAM.VM.Heap.{
    Arrays,
    Async,
    Caches,
    Context,
    GC,
    ProcessKeys,
    Registry,
    Shapes,
    Store
  }

  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor

  @compile {:inline,
            get_obj: 1,
            get_obj: 2,
            get_obj_raw: 1,
            put_obj: 2,
            put_obj_raw: 2,
            update_obj: 3,
            get_cell: 1,
            put_cell: 2,
            put_var: 2,
            delete_var: 1,
            get_ctx: 0,
            put_ctx: 1,
            frozen?: 1,
            freeze: 1,
            extensible?: 1,
            prevent_extensions: 1,
            get_compiled: 1,
            put_compiled: 2,
            get_fn_atoms: 1,
            get_fn_atoms: 2,
            put_fn_atoms: 2,
            get_capture_keys: 1,
            put_capture_keys: 2,
            get_array_proto: 0,
            put_array_proto: 1,
            get_func_proto: 0,
            put_func_proto: 1,
            get_builtin_names: 0,
            put_builtin_names: 1,
            get_regexp_result: 1,
            put_regexp_result: 2,
            get_string_codepoints: 1,
            put_string_codepoints: 2,
            get_array_props: 1,
            get_array_prop: 2,
            put_array_prop: 3,
            delete_array_prop: 2,
            get_class_proto: 1,
            put_class_proto: 2,
            get_parent_ctor: 1,
            put_parent_ctor: 2,
            get_ctor_statics: 1,
            wrap: 1,
            to_list: 1,
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

  @doc "Wraps maps, lists, arrays, and scalar data in a JavaScript object reference."
  def wrap(data) when is_map(data) do
    if is_map_key(data, "__proto__") do
      {proto, rest} = Map.pop!(data, "__proto__")
      wrap_map(rest, proto)
    else
      wrap_map(data, nil)
    end
  end

  def wrap(data) do
    id = Store.next_id()
    put_obj(id, data)
    {:obj, id}
  end

  defp wrap_map(map, proto) do
    case Shapes.from_map(map) do
      {:ok, shape_id, offsets, vals} ->
        wrap_shaped(shape_id, offsets, vals, proto)

      :ineligible ->
        id = Store.next_id()
        data = if proto, do: Map.put(map, "__proto__", proto), else: map
        put_obj(id, data)
        {:obj, id}
    end
  end

  @doc "Returns an object's prototype, falling back to the cached Array prototype for array values."
  def get_array_proto(ref) do
    case Store.get_obj_raw(ref) do
      {:shape, _, _, _, proto} when proto != nil ->
        proto

      map when is_map(map) ->
        Map.get(map, "__proto__")

      _ ->
        case Store.get_array_prop(ref, "__proto__") do
          nil -> Caches.get_array_proto()
          :undefined -> Caches.get_array_proto()
          proto -> proto
        end
    end
  end

  @doc "Wraps a function arguments list as an arguments object."
  def wrap_arguments(args, opts \\ []) when is_list(args) do
    {:obj, ref} = obj = wrap(args)
    put_array_prop(ref, "__arguments__", true)

    case Keyword.get(opts, :mapped) do
      mapped when is_map(mapped) and map_size(mapped) > 0 ->
        put_array_prop(ref, "__mapped_arguments__", mapped)

      _ ->
        :ok
    end

    if Keyword.get(opts, :strict, false) do
      thrower = Keyword.get_lazy(opts, :thrower, &throw_type_error_intrinsic/0)
      put_array_prop(ref, "callee", {:accessor, thrower, thrower})

      put_prop_desc(
        ref,
        "callee",
        PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
      )
    else
      callee = Keyword.get(opts, :callee, :undefined)
      put_array_prop(ref, "callee", callee)

      put_prop_desc(
        ref,
        "callee",
        PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)
      )
    end

    obj
  end

  def throw_type_error_intrinsic(realm_key \\ :default) do
    storage_key = {:qb_throw_type_error_intrinsic, realm_key}

    case Process.get(storage_key) do
      nil ->
        thrower =
          {:builtin, "ThrowTypeError",
           fn _args, _this ->
             message = if realm_key == :default, do: "ThrowTypeError", else: "ThrowTypeError"
             throw({:js_throw, make_error(message, "TypeError")})
           end}

        put_ctor_static(thrower, "length", 0)
        put_ctor_static(thrower, "name", "")

        put_ctor_prop_desc(
          thrower,
          "length",
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
        )

        put_ctor_prop_desc(
          thrower,
          "name",
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
        )

        Process.put(storage_key, thrower)
        thrower

      thrower ->
        thrower
    end
  end

  @doc "Wraps a list as a JavaScript iterator object with a `next` method."
  def wrap_iterator(list) when is_list(list) do
    pos_ref = IteratorState.new({list, 0})

    next_fn =
      {:builtin, "next",
       fn _, _ ->
         case IteratorState.get(pos_ref, nil) do
           {items, idx} when idx < length(items) ->
             IteratorState.put(pos_ref, {items, idx + 1})
             wrap(%{"value" => Enum.at(items, idx), "done" => false})

           _ ->
             wrap(%{"value" => :undefined, "done" => true})
         end
       end}

    wrap(%{
      "next" => next_fn,
      {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _, this -> this end}
    })
  end

  @doc "Fast-wraps an object-literal value tuple with the ordinary Object prototype."
  def wrap_keyed_object_literal(keys, vals) when is_tuple(keys) and is_tuple(vals),
    do: wrap_keyed(keys, vals, get_object_prototype())

  @doc "Fast-wraps a value tuple with a compile-time key tuple, using a cached shape when possible."
  def wrap_keyed(keys, vals) when is_tuple(keys) and is_tuple(vals),
    do: wrap_keyed(keys, vals, nil)

  defp wrap_keyed(keys, vals, proto) when is_tuple(keys) and is_tuple(vals) do
    case Caches.get_wrap_cache(keys) do
      {shape_id, offsets} ->
        id = Store.next_id()
        Store.put_obj_raw(id, {:shape, shape_id, offsets, vals, proto})
        {:obj, id}

      nil ->
        keys_list = Tuple.to_list(keys)
        vals_list = Tuple.to_list(vals)
        map = :maps.from_list(:lists.zip(keys_list, vals_list))

        if Enum.all?(keys_list, &is_binary/1) do
          {shape_id, offsets} =
            Enum.reduce(keys_list, {Shapes.empty_shape_id(), %{}}, fn key, {shape_id, _offsets} ->
              {next_shape_id, next_offsets, _offset} = Shapes.transition(shape_id, key)
              {next_shape_id, next_offsets}
            end)

          Caches.put_wrap_cache(keys, {shape_id, offsets})
          id = Store.next_id()
          Store.put_obj_raw(id, {:shape, shape_id, offsets, vals, proto})
          {:obj, id}
        else
          wrap(map)
        end
    end
  end

  @doc "Fast allocation with a pre-resolved shape. Skips eligibility check and key sorting."
  def wrap_shaped(shape_id, offsets, vals, proto) do
    id = Store.next_id()
    Store.put_obj_raw(id, {:shape, shape_id, offsets, vals, proto})
    {:obj, id}
  end

  @doc "Converts JavaScript array-like VM values to Elixir lists."
  def to_list({:obj, ref}) do
    case Process.get(ref, []) do
      {:qb_arr, arr} ->
        :array.to_list(arr)

      list when is_list(list) ->
        list

      {:shape, _shape_id, _offsets, _vals, _proto} ->
        []

      map when is_map(map) ->
        len = Map.get(map, "length", 0)

        if is_integer(len) and len > 0,
          do: for(i <- 0..(len - 1), do: Map.get(map, Integer.to_string(i), :undefined)),
          else: []

      _ ->
        []
    end
  end

  def to_list({:qb_arr, _} = arr), do: Arrays.to_list(arr)
  def to_list(list) when is_list(list), do: list
  def to_list(_), do: []

  @doc "Creates a JavaScript Error-like object with message, name, prototype, and stack metadata."
  def make_error(message, name) do
    proto =
      case find_error_proto(name) do
        nil -> nil
        ctor -> get_class_proto(ctor)
      end

    base = %{
      "message" => message,
      "name" => name,
      "stack" => "",
      "__error_name__" => name,
      {:symbol, "Symbol.toStringTag"} => "Error"
    }

    error = if proto, do: wrap(Map.put(base, "__proto__", proto)), else: wrap(base)

    with {:obj, ref} <- error do
      for key <- ["message", "name", "stack"] do
        put_prop_desc(ref, key, %{writable: true, enumerable: false, configurable: true})
      end

      put_prop_desc(ref, {:symbol, "Symbol.toStringTag"}, %{
        writable: true,
        enumerable: false,
        configurable: true
      })
    end

    if get_ctx() != nil,
      do: QuickBEAM.VM.Stacktrace.attach_stack(error),
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

  @doc "Returns an existing constructor prototype or lazily creates one for function constructors."
  def get_or_create_prototype(ctor) do
    case get_class_proto(ctor) do
      nil ->
        # Use stable key based on bytecode identity, not closure tuple reference
        stable_key = proto_cache_key(ctor)
        key = {:qb_func_proto, stable_key}

        case Process.get(key) do
          nil ->
            obj_proto = function_prototype_parent(ctor)
            proto_map = %{"constructor" => ctor}

            proto_map =
              if obj_proto, do: Map.put(proto_map, "__proto__", obj_proto), else: proto_map

            proto = wrap(proto_map)
            Process.put(key, proto)

            put_prop_desc(ctor, "prototype", %{
              writable: true,
              enumerable: false,
              configurable: false
            })

            proto

          existing ->
            existing
        end

      proto ->
        proto
    end
  end

  # ── Objects ──

  defp function_prototype_parent({:closure, _, %QuickBEAM.VM.Function{func_kind: 1}}),
    do: generator_prototype_object()

  defp function_prototype_parent(%QuickBEAM.VM.Function{func_kind: 1}),
    do: generator_prototype_object()

  defp function_prototype_parent(_ctor), do: get_object_prototype()

  def get_or_create_generator_prototype_object, do: generator_prototype_object()

  defp generator_prototype_object do
    case Process.get(:qb_generator_prototype_object) do
      {:obj, _} = proto ->
        proto

      _ ->
        proto = QuickBEAM.VM.Interpreter.Generator.prototype_object()

        Process.put(:qb_generator_prototype_object, proto)
        proto
    end
  end

  defp proto_cache_key({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: proto_cache_key(fun)
  defp proto_cache_key(%QuickBEAM.VM.Function{id: id}) when is_integer(id), do: {:function, id}
  defp proto_cache_key(%QuickBEAM.VM.Function{} = fun), do: {:function, :erlang.phash2(fun)}
  defp proto_cache_key(ctor), do: ctor

  @doc "Returns heap object data, reconstructing shaped objects as maps."
  defdelegate get_obj(ref), to: Store
  defdelegate get_obj(ref, default), to: Store
  defdelegate get_obj_raw(ref), to: Store
  defdelegate shape?(raw), to: Store
  defdelegate shape_offsets(raw), to: Store
  defdelegate shape_proto(raw), to: Store
  defdelegate shape_keys(raw), to: Store
  defdelegate shape_to_map(raw), to: Store
  defdelegate raw_fetch(raw, key), to: Store
  defdelegate raw_has_key?(raw, key), to: Store
  defdelegate raw_proto(raw), to: Store
  defdelegate raw_accessor_setter(raw, key), to: Store
  defdelegate raw_getter_only?(raw, key), to: Store
  defdelegate raw_accessor?(raw, key), to: Store
  defdelegate put_obj(ref, value), to: Store
  defdelegate put_obj_raw(ref, value), to: Store
  defdelegate put_obj_key(ref, key, value), to: Store
  defdelegate put_obj_key(ref, map, key, value), to: Store
  defdelegate put_shape_proto(ref, proto), to: Store
  defdelegate update_obj(ref, default, fun), to: Store

  # ── Array helpers ──

  @doc "Returns a heap object as a list when it stores array-like data."
  defdelegate obj_to_list(ref), to: Store
  defdelegate array_get(ref, idx), to: Store
  defdelegate array_size(ref), to: Store
  defdelegate array_push(ref, values), to: Store
  defdelegate array_set(ref, idx, value), to: Store

  # ── Closure cells ──

  @doc "Reads a closure/capture cell value."
  defdelegate get_cell(ref), to: Store
  defdelegate put_cell(ref, value), to: Store

  # ── Class metadata ──

  defdelegate get_class_proto(ctor), to: Store
  defdelegate put_class_proto(ctor, proto), to: Store
  defdelegate get_parent_ctor(ctor), to: Store
  @doc "Stores the parent constructor associated with a class constructor."
  defdelegate put_parent_ctor(ctor, parent), to: Store
  defdelegate delete_parent_ctor(ctor), to: Store
  defdelegate get_ctor_statics(ctor), to: Store
  defdelegate put_ctor_statics(ctor, statics), to: Store
  defdelegate put_ctor_static(ctor, key, value), to: Store
  defdelegate get_ctor_prop_desc(ctor, key), to: Store
  defdelegate put_ctor_prop_desc(ctor, key, desc), to: Store
  defdelegate put_var(name, value), to: Store
  defdelegate delete_var(name), to: Store

  # ── Interpreter context ──

  @doc "Returns the active interpreter context stored in the process dictionary."
  defdelegate get_ctx(), to: Context
  defdelegate put_ctx(ctx), to: Context
  defdelegate get_compiled(key), to: Caches
  defdelegate put_compiled(key, compiled), to: Caches
  defdelegate get_fn_atoms(function_or_key), to: Caches
  defdelegate get_fn_atoms(function_or_key, default), to: Caches
  @doc "Caches the atom table for a VM function."
  defdelegate put_fn_atoms(function_or_key, atoms), to: Caches
  defdelegate get_capture_keys(function_or_key), to: Caches
  defdelegate put_capture_keys(function_or_key, tuple), to: Caches
  defdelegate get_array_proto(), to: Caches
  defdelegate put_array_proto(proto), to: Caches
  defdelegate get_func_proto(), to: Caches
  defdelegate put_func_proto(proto), to: Caches
  defdelegate get_builtin_names(), to: Caches
  @doc "Stores builtin-name metadata."
  defdelegate put_builtin_names(names), to: Caches
  defdelegate get_regexp_result(ref), to: Caches
  defdelegate put_regexp_result(ref, result), to: Caches
  defdelegate get_string_codepoints(s), to: Caches
  defdelegate put_string_codepoints(s, chars), to: Caches
  defdelegate get_invoke_depth(), to: Caches
  defdelegate put_invoke_depth(depth), to: Caches
  defdelegate get_eval_restore_stack(), to: Caches
  @doc "Stores the eval restore stack for the current process."
  defdelegate put_eval_restore_stack(stack), to: Caches
  defdelegate frozen?(ref), to: Store
  defdelegate freeze(ref), to: Store
  defdelegate extensible?(ref), to: Store
  defdelegate prevent_extensions(ref), to: Store
  defdelegate get_prop_desc(ref, key), to: Store
  defdelegate put_prop_desc(ref, key, desc), to: Store
  defdelegate delete_prop_desc(ref, key), to: Store
  defdelegate get_array_props(ref), to: Store
  defdelegate get_array_prop(ref, key), to: Store
  defdelegate put_array_prop(ref, key, val), to: Store
  defdelegate delete_array_prop(ref, key), to: Store
  defdelegate get_object_prototype(), to: Context
  defdelegate put_object_prototype(proto), to: Context
  defdelegate get_global_cache(), to: Context
  @doc "Stores cached global bindings and invalidates derived base globals."
  defdelegate put_global_cache(bindings), to: Context
  defdelegate get_base_globals(), to: Context
  defdelegate put_base_globals(globals), to: Context
  defdelegate get_atoms(), to: Context
  defdelegate put_atoms(atoms), to: Context
  defdelegate get_persistent_globals(), to: Context
  defdelegate put_persistent_globals(globals), to: Context
  defdelegate get_handler_globals(), to: Context
  @doc "Stores host-provided handler globals and invalidates derived base globals."
  defdelegate put_handler_globals(globals), to: Context
  defdelegate get_runtime_mode(runtime), to: Context
  defdelegate put_runtime_mode(runtime, mode), to: Context
  defdelegate enqueue_microtask(task), to: Async
  defdelegate microtasks_empty?(), to: Async
  defdelegate dequeue_microtask(), to: Async
  defdelegate get_promise_waiters(ref), to: Async
  defdelegate put_promise_waiters(ref, waiters), to: Async
  defdelegate delete_promise_waiters(ref), to: Async
  @doc "Registers a compiled module and its exports in the process-local registry."
  defdelegate register_module(name, exports), to: Registry
  defdelegate get_module(name), to: Registry
  defdelegate all_module_exports(), to: Registry
  defdelegate get_symbol(key), to: Registry
  defdelegate put_symbol(key, sym), to: Registry

  # ── Garbage collection ──

  @doc "Returns the allocation threshold that triggers the first heap GC pass."
  defdelegate gc_initial_threshold(), to: GC
  defdelegate gc_needed?(), to: GC
  defdelegate mark_and_sweep(roots), to: GC
  defdelegate with_temp_roots(roots, fun), to: GC

  @doc "Clear all heap state. Used in test setup."
  def reset do
    for key <- Process.get_keys(), ProcessKeys.owned_entry?(key, Process.get(key)) do
      Process.delete(key)
    end

    :ok
  end

  @doc "Captures the mutable BEAM VM heap state for later restoration."
  def snapshot do
    entries =
      for key <- Process.get_keys(),
          ProcessKeys.owned_entry?(key, Process.get(key)),
          not snapshot_preserved_key?(key),
          into: %{} do
        {key, Process.get(key)}
      end

    %{entries: entries}
  end

  @doc "Restores a heap snapshot created by snapshot/0 while preserving safe caches."
  def restore(%{entries: entries}) when is_map(entries) do
    for key <- Process.get_keys(),
        ProcessKeys.owned_entry?(key, Process.get(key)),
        not snapshot_preserved_key?(key) do
      Process.delete(key)
    end

    Enum.each(entries, fn {key, value} -> Process.put(key, value) end)
    :ok
  end

  defp snapshot_preserved_key?({:qb_compiled, _}), do: true
  defp snapshot_preserved_key?(_), do: false

  @doc "Runs heap garbage collection using the active VM roots plus extra roots."
  defdelegate gc(extra_roots \\ []), to: GC
end
