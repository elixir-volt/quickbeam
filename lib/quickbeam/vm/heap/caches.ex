defmodule QuickBEAM.VM.Heap.Caches do
  @moduledoc false

  # ── Bytecode caches ──

  def get_decoded(byte_code), do: Process.get({:qb_decoded, byte_code})

  def put_decoded(byte_code, instructions),
    do: Process.put({:qb_decoded, byte_code}, instructions)

  def get_compiled(key), do: Process.get({:qb_compiled, key})
  def put_compiled(key, compiled), do: Process.put({:qb_compiled, key}, compiled)

  def get_fn_atoms(byte_code, default \\ nil),
    do: Process.get({:qb_fn_atoms, byte_code}, default)

  def put_fn_atoms(byte_code, atoms), do: Process.put({:qb_fn_atoms, byte_code}, atoms)

  def get_capture_keys(byte_code), do: Process.get({:qb_capture_keys, byte_code})
  def put_capture_keys(byte_code, tuple), do: Process.put({:qb_capture_keys, byte_code}, tuple)

  def get_wrap_cache(keys_tuple), do: Process.get({:qb_wrap_cache, keys_tuple})

  def put_wrap_cache(keys_tuple, shape_info),
    do: Process.put({:qb_wrap_cache, keys_tuple}, shape_info)

  # ── Runtime prototype caches ──

  def get_array_proto, do: Process.get(:qb_array_proto)
  def put_array_proto(proto), do: Process.put(:qb_array_proto, proto)

  def get_func_proto, do: Process.get(:qb_func_proto)
  def put_func_proto(proto), do: Process.put(:qb_func_proto, proto)

  def get_builtin_names, do: Process.get(:qb_builtin_names)
  def put_builtin_names(names), do: Process.put(:qb_builtin_names, names)

  # ── Per-call ephemeral caches ──

  def get_regexp_result(ref), do: Process.get({:qb_regexp_result, ref})
  def put_regexp_result(ref, result), do: Process.put({:qb_regexp_result, ref}, result)

  def get_string_codepoints(s), do: Process.get({:qb_string_codepoints, s})
  def put_string_codepoints(s, chars), do: Process.put({:qb_string_codepoints, s}, chars)
end
