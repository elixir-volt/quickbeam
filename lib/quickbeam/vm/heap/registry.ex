defmodule QuickBEAM.VM.Heap.Registry do
  @moduledoc """
  Documents all process dictionary keys used by the BEAM VM, and owns
  module/symbol registration.

  ## Heap objects
  - `integer_id` (positive integer) — JS object/array data (map, list, shape, `{:qb_arr, …}`)
  - `{:qb_cell, ref}` — closure variable cell

  ## Object metadata (ephemeral — cleared by GC)
  - `{:qb_prop_desc, ref, key}` — property descriptor override
  - `{:qb_frozen, ref}` — frozen-object flag
  - `{:qb_var, name}` — global variable binding
  - `{:qb_key_order, ref}` — explicit property insertion order

  ## Constructor / class metadata
  - `{:qb_class_proto, fun}` — class prototype object
  - `{:qb_func_proto, fun}` — Function.prototype ref (per closure)
  - `{:qb_parent_ctor, fun}` — parent constructor reference
  - `{:qb_ctor_statics, fun}` — constructor static properties map
  - `{:qb_home_object, bytecode_ref}` — home object for `super` dispatch

  ## Interpreter context
  - `:qb_ctx` — current interpreter `Context` struct
  - `:qb_fast_ctx` — fast-path context tuple (atoms, globals, func, arg_buf, this, new_target, home_object, super)
  - `:qb_atoms` — predefined atom table (tuple of strings)
  - `:qb_object_prototype` — Object.prototype heap ref
  - `:qb_array_proto` — Array.prototype heap ref (set by globals initializer)
  - `:qb_func_proto` — global Function.prototype heap ref

  ## Globals / modules
  - `:qb_persistent_globals` — globals that survive `gc/0`
  - `:qb_handler_globals` — handler-installed globals
  - `:qb_global_bindings_cache` — cached runtime global bindings map
  - `:qb_base_globals_cache` — merged base-globals cache
  - `{:qb_runtime_mode, runtime_pid}` — per-runtime execution mode
  - `{:qb_module, name}` — exported bindings for a named module
  - `:qb_module_list` — list of registered module names
  - `{:qb_symbol_registry, key}` — global Symbol registry entry

  ## Caches (safe to drop — recomputed on demand)
  - `{:qb_compiled, key}` — compiled function cache
  - `{:qb_decoded, key}` — decoded bytecode instruction cache
  - `{:qb_fn_atoms, bytecode}` — per-function atom table cache
  - `{:qb_capture_keys, bytecode}` — closure capture-key tuple cache
  - `{:qb_wrap_cache, keys_tuple}` — shape info cache for `Heap.wrap_keyed/2`
  - `{:qb_regexp_result, ref}` — last RegExp exec result (indices, groups)
  - `{:qb_string_codepoints, string}` — codepoint list cache for string iteration
  - `:qb_builtin_names` — `MapSet` of built-in global names (for `typeof` guard)
  - `:qb_shape_table` — shape-id → key-list table
  - `:qb_shape_empty` — empty shape id
  - `:qb_shape_next_id` — next shape id counter

  ## GC bookkeeping
  - `:qb_alloc_count` — live object count after last GC
  - `:qb_gc_threshold` — allocation count that triggers next GC
  - `:qb_gc_needed` — flag set when threshold is exceeded
  - `:qb_next_id` — monotonic heap object id counter

  ## Ephemeral / call-stack
  - `:qb_invoke_depth` — current synchronous call-stack depth
  - `:qb_eval_restore_stack` — per-eval object-mutation undo log
  - `:qb_function_type_stack` — compile-time function-type inference stack
  - `:qb_active_frames` — stacktrace frame list
  - `{:qb_promise_waiters, ref}` — promise continuation list

  ## Misc
  - `{:qb_microtask_queue, …}` — microtask queue entries

  ## Timer state
  - `:qb_timer_queue` — list of pending timer entries (setTimeout/setInterval)
  - `:qb_timer_next_id` — monotonic counter for timer IDs
  """

  @doc "Registers a compiled module and its exports in the process-local registry."
  def register_module(name, exports) do
    Process.put({:qb_module, name}, exports)
    existing = Process.get(:qb_module_list, [])
    unless name in existing, do: Process.put(:qb_module_list, [name | existing])
  end

  def get_module(name), do: Process.get({:qb_module, name})

  @doc "Returns all registered module exports."
  def all_module_exports do
    Process.get(:qb_module_list, [])
    |> Enum.map(&Process.get({:qb_module, &1}))
    |> Enum.reject(&is_nil/1)
  end

  def get_symbol(key), do: Process.get({:qb_symbol_registry, key})
  def put_symbol(key, sym), do: Process.put({:qb_symbol_registry, key}, sym)
end
