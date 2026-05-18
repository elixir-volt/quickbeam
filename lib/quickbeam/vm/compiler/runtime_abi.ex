defmodule QuickBEAM.VM.Compiler.RuntimeABI do
  @moduledoc """
  Stable runtime ABI called from lowered BEAM compiler output.

  `RuntimeHelpers` remains the implementation façade. This module names the
  subset of helpers that generated code should treat as ABI: operations whose
  calling convention is part of compiler lowering rather than an implementation
  detail of a particular helper module.
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

  def iterator_close_refresh(ctx, iter_obj), do: RuntimeHelpers.iterator_close_refresh(ctx, iter_obj)

  def iterator_close_for_throw(ctx, iter_obj),
    do: RuntimeHelpers.iterator_close_for_throw(ctx, iter_obj)

  def collect_iterator(ctx, iter, next_fn),
    do: RuntimeHelpers.collect_iterator(ctx, iter, next_fn)
end
