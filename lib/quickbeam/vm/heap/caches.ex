defmodule QuickBEAM.VM.Heap.Caches do
  @moduledoc "Process-local caches for decoded bytecode, prototypes, transient call state, and runtime metadata."

  alias QuickBEAM.VM.Bytecode

  # ── Bytecode caches ──

  @doc "Returns cached decoded instructions for a bytecode binary."
  def get_decoded(byte_code), do: Process.get({:qb_decoded, byte_code})

  def put_decoded(byte_code, instructions),
    do: Process.put({:qb_decoded, byte_code}, instructions)

  @doc "Returns cached compiled code for a compiler cache key."
  def get_compiled(key), do: Process.get({:qb_compiled, key})
  def put_compiled(key, compiled), do: Process.put({:qb_compiled, key}, compiled)

  def get_fn_atoms(function_or_byte_code, default \\ nil)

  def get_fn_atoms(%Bytecode.Function{atoms: atoms}, _default) when not is_nil(atoms), do: atoms

  def get_fn_atoms(%Bytecode.Function{} = fun, default) do
    Process.get({:qb_fn_atoms, function_atom_key(fun)}, bytecode_atoms(fun, default))
  end

  def get_fn_atoms(byte_code, default), do: Process.get({:qb_fn_atoms, byte_code}, default)

  @doc "Caches the atom table for a bytecode function."
  def put_fn_atoms(%Bytecode.Function{} = fun, atoms) do
    Process.put({:qb_fn_atoms, function_atom_key(fun)}, atoms)

    if is_binary(fun.byte_code) and byte_size(fun.byte_code) > 0 do
      Process.put({:qb_fn_atoms, fun.byte_code}, atoms)
    end
  end

  def put_fn_atoms(byte_code, atoms), do: Process.put({:qb_fn_atoms, byte_code}, atoms)

  defp function_atom_key(%Bytecode.Function{instructions: instructions} = fun)
       when is_tuple(instructions),
       do: {:instructions, :erlang.phash2(instructions), fun.arg_count, :erlang.phash2(fun)}

  defp function_atom_key(%Bytecode.Function{} = fun),
    do: {:byte_code, fun.byte_code, fun.arg_count, :erlang.phash2(fun)}

  defp bytecode_atoms(%Bytecode.Function{byte_code: byte_code}, default)
       when is_binary(byte_code) and byte_size(byte_code) > 0,
       do: get_fn_atoms(byte_code, default)

  defp bytecode_atoms(%Bytecode.Function{}, default), do: default

  def get_capture_keys(%Bytecode.Function{} = fun),
    do: Process.get({:qb_capture_keys, function_atom_key(fun)}, get_capture_keys(fun.byte_code))

  def get_capture_keys(byte_code), do: Process.get({:qb_capture_keys, byte_code})

  def put_capture_keys(%Bytecode.Function{} = fun, tuple),
    do: Process.put({:qb_capture_keys, function_atom_key(fun)}, tuple)

  def put_capture_keys(byte_code, tuple), do: Process.put({:qb_capture_keys, byte_code}, tuple)

  @doc "Returns cached object-shape wrapping metadata for a key tuple."
  def get_wrap_cache(keys_tuple), do: Process.get({:qb_wrap_cache, keys_tuple})

  def put_wrap_cache(keys_tuple, shape_info),
    do: Process.put({:qb_wrap_cache, keys_tuple}, shape_info)

  # ── Runtime prototype caches ──

  @doc "Returns the process-local Array prototype object."
  def get_array_proto, do: Process.get(:qb_array_proto)
  def put_array_proto(proto), do: Process.put(:qb_array_proto, proto)

  def get_func_proto, do: Process.get(:qb_func_proto)
  def put_func_proto(proto), do: Process.put(:qb_func_proto, proto)

  @doc "Returns cached builtin-name metadata."
  def get_builtin_names, do: Process.get(:qb_builtin_names)
  def put_builtin_names(names), do: Process.put(:qb_builtin_names, names)

  # ── Per-call ephemeral caches ──

  @doc "Returns cached RegExp match result data for an object reference."
  def get_regexp_result(ref), do: Process.get({:qb_regexp_result, ref})
  def put_regexp_result(ref, result), do: Process.put({:qb_regexp_result, ref}, result)

  def get_string_codepoints(s), do: Process.get({:qb_string_codepoints, s})
  def put_string_codepoints(s, chars), do: Process.put({:qb_string_codepoints, s}, chars)

  # ── Invocation depth ──

  @doc "Returns the current runtime invocation depth."
  def get_invoke_depth, do: Process.get(:qb_invoke_depth, 0)
  def put_invoke_depth(depth), do: Process.put(:qb_invoke_depth, depth)

  # ── Eval restore stack ──

  @doc "Returns the eval restore stack for the current process."
  def get_eval_restore_stack, do: Process.get(:qb_eval_restore_stack, [])
  def put_eval_restore_stack(stack), do: Process.put(:qb_eval_restore_stack, stack)

  # ── Function type inference recursion guard ──

  @doc "Returns the recursion guard set used during function type inference."
  def get_function_type_stack, do: Process.get(:qb_function_type_stack, MapSet.new())
  def put_function_type_stack(stack), do: Process.put(:qb_function_type_stack, stack)
  def delete_function_type_stack, do: Process.delete(:qb_function_type_stack)

  # ── Home object storage ──

  @doc "Returns cached home-object metadata for a function key."
  def get_home_object(key), do: Process.get({:qb_home_object, key}, :undefined)
  def put_home_object(key, target), do: Process.put({:qb_home_object, key}, target)

  # ── Timer state ──

  @doc "Returns the process-local timer queue."
  def get_timer_queue, do: Process.get(:qb_timer_queue, [])
  def put_timer_queue(queue), do: Process.put(:qb_timer_queue, queue)
  def get_timer_next_id, do: Process.get(:qb_timer_next_id, 1)
  def put_timer_next_id(id), do: Process.put(:qb_timer_next_id, id)
end
