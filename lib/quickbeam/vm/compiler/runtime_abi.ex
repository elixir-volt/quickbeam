defmodule QuickBEAM.VM.Compiler.RuntimeABI do
  @moduledoc """
  Stable runtime ABI called from lowered BEAM compiler output.

  `RuntimeHelpers` remains the implementation façade. This module names the
  subset of helpers that generated code should treat as ABI: operations whose
  calling convention is part of compiler lowering rather than an implementation
  detail of a particular helper module.

  Spec boundary examples:

  | ABI helper | ECMA relation |
  |---|---|
  | `to_object/2` | §7.1.18 ToObject |
  | `to_property_key/2` | §7.1.19 ToPropertyKey |
  | `copy_data_properties/4` | §7.3.25 CopyDataProperties |
  | `get_field/3` | §7.3.2 Get, §10.1.8 [[Get]] |
  | `put_field/4` | §7.3.4 Set, §10.1.9 [[Set]] |
  | `for_of_start/2` | §7.4.1 GetIterator / iterator setup for bytecode |
  | `iterator_next_result/4` | §7.4.6 IteratorNext |
  | `iterator_close/2` | §7.4.11 IteratorClose |

  Generated code should prefer this ABI for spec-sensitive behavior. Direct
  calls to `RuntimeHelpers` should remain compiler-private mechanics or migrate
  here when they become part of generated-code semantics.
  """

  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  def to_object(_ctx, value), do: RuntimeHelpers.to_object(value)

  def to_property_key(ctx, value), do: RuntimeHelpers.to_property_key(ctx, value)

  def to_property_key_for_access(ctx, receiver, key),
    do: RuntimeHelpers.to_property_key_for_access(ctx, receiver, key)

  def copy_data_properties(ctx, target, source, exclude),
    do: RuntimeHelpers.copy_data_properties(ctx, target, source, exclude)

  def special_object(ctx, type), do: RuntimeHelpers.special_object(ctx, type)

  def get_array_el(ctx, obj, index), do: RuntimeHelpers.get_array_el(ctx, obj, index)

  def get_array_el2(ctx, obj, index), do: RuntimeHelpers.get_array_el2(ctx, obj, index)

  def put_array_el(ctx, obj, index, value),
    do: RuntimeHelpers.put_array_el(ctx, obj, index, value)

  def get_field(ctx, obj, key), do: RuntimeHelpers.get_field(ctx, obj, key)

  def put_field(ctx, obj, key, value), do: RuntimeHelpers.put_field(ctx, obj, key, value)

  def delete_property(ctx, obj, key), do: RuntimeHelpers.delete_property(ctx, obj, key)

  def in_operator(ctx, key, obj), do: RuntimeHelpers.in_operator(ctx, key, obj)

  def append_spread(ctx, arr, idx, obj), do: RuntimeHelpers.append_spread(ctx, arr, idx, obj)

  def assignment_with_iterator_close(ctx, fun, iterators, obj, key, value),
    do: RuntimeHelpers.assignment_with_iterator_close(ctx, fun, iterators, obj, key, value)

  def for_of_start(ctx, obj), do: RuntimeHelpers.for_of_start(ctx, obj)

  def for_of_next(ctx, next_fn, iter_obj), do: RuntimeHelpers.for_of_next(ctx, next_fn, iter_obj)

  def iterator_next_result(ctx, next_fn, iter_obj, value),
    do: RuntimeHelpers.iterator_next_result(ctx, next_fn, iter_obj, value)

  def iterator_check_object(ctx, value), do: RuntimeHelpers.iterator_check_object(ctx, value)

  def iterator_call(ctx, flags, value, catch_offset, next_fn, iter_obj),
    do: RuntimeHelpers.iterator_call(ctx, flags, value, catch_offset, next_fn, iter_obj)

  def for_in_start(ctx, obj), do: RuntimeHelpers.for_in_start(ctx, obj)

  def for_in_next(ctx, iter), do: RuntimeHelpers.for_in_next(ctx, iter)

  def iterator_value_done(_ctx, result), do: RuntimeHelpers.iterator_value_done(result)

  def iterator_close(ctx, iter_obj), do: RuntimeHelpers.iterator_close(ctx, iter_obj)

  def iterator_close_refresh(ctx, iter_obj),
    do: RuntimeHelpers.iterator_close_refresh(ctx, iter_obj)

  def iterator_close_for_throw(ctx, iter_obj),
    do: RuntimeHelpers.iterator_close_for_throw(ctx, iter_obj)

  def collect_iterator(ctx, iter, next_fn),
    do: RuntimeHelpers.collect_iterator(ctx, iter, next_fn)
end
