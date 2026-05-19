defmodule QuickBEAM.VM.Compiler.RuntimeABI do
  @moduledoc """
  Stable runtime ABI called from lowered BEAM compiler output.

  This module names the helpers that generated code should treat as ABI:
  operations whose calling convention is part of compiler lowering rather than
  an implementation detail of a particular helper module.

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

  def push_this(ctx), do: RuntimeHelpers.push_this(ctx)

  def ensure_capture_cell(ctx, cell, value),
    do: RuntimeHelpers.ensure_capture_cell(ctx, cell, value)

  def close_capture_cell(ctx, cell, value),
    do: RuntimeHelpers.close_capture_cell(ctx, cell, value)

  def sync_capture_cell(ctx, cell, value), do: RuntimeHelpers.sync_capture_cell(ctx, cell, value)

  def get_capture(ctx, key), do: RuntimeHelpers.get_capture(ctx, key)

  def get_var(ctx, name), do: RuntimeHelpers.get_var(ctx, name)

  def get_var_undef(ctx, name), do: RuntimeHelpers.get_var_undef(ctx, name)

  def delete_var(ctx, atom_idx), do: RuntimeHelpers.delete_var(ctx, atom_idx)

  def put_var_ref(ctx, idx, value), do: RuntimeHelpers.put_var_ref(ctx, idx, value)

  def set_var_ref(ctx, idx, value), do: RuntimeHelpers.set_var_ref(ctx, idx, value)

  def make_loc_ref(ctx, idx, value), do: RuntimeHelpers.make_loc_ref(ctx, idx, value)

  def make_arg_ref(ctx, idx), do: RuntimeHelpers.make_arg_ref(ctx, idx)

  def make_var_ref(ctx, atom_idx), do: RuntimeHelpers.make_var_ref(ctx, atom_idx)

  def make_var_ref_ref(ctx, idx), do: RuntimeHelpers.make_var_ref_ref(ctx, idx)

  def get_ref_value(ctx, key, ref), do: RuntimeHelpers.get_ref_value(ctx, key, ref)

  def put_ref_value(ctx, value, key, ref), do: RuntimeHelpers.put_ref_value(ctx, value, key, ref)

  def ensure_initialized_local!(ctx, value),
    do: RuntimeHelpers.ensure_initialized_local!(ctx, value)

  def undefined?(ctx, value), do: RuntimeHelpers.undefined?(ctx, value)

  def null?(ctx, value), do: RuntimeHelpers.null?(ctx, value)

  def typeof_is_undefined(ctx, value), do: RuntimeHelpers.typeof_is_undefined(ctx, value)

  def typeof_is_function(ctx, value), do: RuntimeHelpers.typeof_is_function(ctx, value)

  def strict_neq(ctx, left, right), do: RuntimeHelpers.strict_neq(ctx, left, right)

  def bit_not(ctx, value), do: RuntimeHelpers.bit_not(ctx, value)

  def lnot(ctx, value), do: RuntimeHelpers.lnot(ctx, value)

  def inc(ctx, value), do: RuntimeHelpers.inc(ctx, value)

  def dec(ctx, value), do: RuntimeHelpers.dec(ctx, value)

  def post_inc(ctx, value), do: RuntimeHelpers.post_inc(ctx, value)

  def post_dec(ctx, value), do: RuntimeHelpers.post_dec(ctx, value)

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

  def new_object(ctx), do: RuntimeHelpers.new_object(ctx)

  def set_proto(ctx, obj, proto), do: RuntimeHelpers.set_proto(ctx, obj, proto)

  def define_array_el(ctx, obj, index, value),
    do: RuntimeHelpers.define_array_el(ctx, obj, index, value)

  def define_field(ctx, obj, key, value), do: RuntimeHelpers.define_field(ctx, obj, key, value)

  def define_static_method(ctx, ctor, key, method),
    do: RuntimeHelpers.define_static_method(ctx, ctor, key, method)

  def define_method(ctx, target, method, name, flags),
    do: RuntimeHelpers.define_method(ctx, target, method, name, flags)

  def define_method_computed(ctx, target, method, field_name, flags),
    do: RuntimeHelpers.define_method_computed(ctx, target, method, field_name, flags)

  def define_class(ctx, ctor, parent_ctor, atom_idx),
    do: RuntimeHelpers.define_class(ctx, ctor, parent_ctor, atom_idx)

  def define_class_computed(ctx, ctor, parent_ctor, computed_name),
    do: RuntimeHelpers.define_class_computed(ctx, ctor, parent_ctor, computed_name)

  def get_private_field(ctx, obj, key), do: RuntimeHelpers.get_private_field(ctx, obj, key)

  def put_private_field(ctx, obj, key, value),
    do: RuntimeHelpers.put_private_field(ctx, obj, key, value)

  def define_private_field(ctx, obj, key, value),
    do: RuntimeHelpers.define_private_field(ctx, obj, key, value)

  def check_brand(ctx, obj, brand), do: RuntimeHelpers.check_brand(ctx, obj, brand)

  def set_function_name(ctx, fun, name), do: RuntimeHelpers.set_function_name(ctx, fun, name)

  def set_function_name_computed(ctx, fun, name_value),
    do: RuntimeHelpers.set_function_name_computed(ctx, fun, name_value)

  def set_home_object(ctx, method, target),
    do: RuntimeHelpers.set_home_object(ctx, method, target)

  def add_brand(ctx, obj, brand), do: RuntimeHelpers.add_brand(ctx, obj, brand)

  def check_ctor_return(ctx, value), do: RuntimeHelpers.check_ctor_return(ctx, value)

  def init_ctor(ctx), do: RuntimeHelpers.init_ctor(ctx)

  def construct_runtime(ctx, ctor, new_target, args),
    do: RuntimeHelpers.construct_runtime(ctx, ctor, new_target, args)

  def construct_runtime(ctx, ctor, new_target, args, call_pc),
    do: RuntimeHelpers.construct_runtime(ctx, ctor, new_target, args, call_pc)

  def apply_super(ctx, fun, new_target, args),
    do: RuntimeHelpers.apply_super(ctx, fun, new_target, args)

  def update_this(ctx, this_value), do: RuntimeHelpers.update_this(ctx, this_value)

  def eval_or_call(ctx, fun, args), do: RuntimeHelpers.eval_or_call(ctx, fun, args)

  def import_module(ctx, specifier), do: RuntimeHelpers.import_module(ctx, specifier)

  def throw_error(ctx, atom_idx, reason), do: RuntimeHelpers.throw_error(ctx, atom_idx, reason)

  def array_from(ctx, list), do: RuntimeHelpers.array_from(ctx, list)

  def with_has_property(ctx, obj, key), do: RuntimeHelpers.with_has_property(ctx, obj, key)

  def rest(ctx, start_idx), do: RuntimeHelpers.rest(ctx, start_idx)

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
