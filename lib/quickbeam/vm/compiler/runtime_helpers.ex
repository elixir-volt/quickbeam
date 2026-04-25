defmodule QuickBEAM.VM.Compiler.RuntimeHelpers do
  @moduledoc "Runtime support for JIT-compiled code. Delegates to focused submodules."

  alias __MODULE__.{Coercion, Functions, Iterators, Objects, Variables}

  # --- Coercion ---
  defdelegate entry_ctx(), to: Coercion
  defdelegate ensure_initialized_local!(val), to: Coercion
  defdelegate ensure_initialized_local!(ctx, val), to: Coercion
  defdelegate undefined?(val), to: Coercion
  defdelegate undefined?(ctx, val), to: Coercion
  defdelegate null?(val), to: Coercion
  defdelegate null?(ctx, val), to: Coercion
  defdelegate typeof_is_undefined(val), to: Coercion
  defdelegate typeof_is_undefined(ctx, val), to: Coercion
  defdelegate typeof_is_function(val), to: Coercion
  defdelegate typeof_is_function(ctx, val), to: Coercion
  defdelegate strict_neq(a, b), to: Coercion
  defdelegate strict_neq(ctx, a, b), to: Coercion
  defdelegate bit_not(a), to: Coercion
  defdelegate bit_not(ctx, a), to: Coercion
  defdelegate lnot(a), to: Coercion
  defdelegate lnot(ctx, a), to: Coercion
  defdelegate inc(a), to: Coercion
  defdelegate inc(ctx, a), to: Coercion
  defdelegate dec(a), to: Coercion
  defdelegate dec(ctx, a), to: Coercion
  defdelegate post_inc(a), to: Coercion
  defdelegate post_inc(ctx, a), to: Coercion
  defdelegate post_dec(a), to: Coercion
  defdelegate post_dec(ctx, a), to: Coercion
  defdelegate ensure_capture_cell(cell, val), to: Coercion
  defdelegate ensure_capture_cell(ctx, cell, val), to: Coercion
  defdelegate close_capture_cell(cell, val), to: Coercion
  defdelegate close_capture_cell(ctx, cell, val), to: Coercion
  defdelegate sync_capture_cell(cell, val), to: Coercion
  defdelegate sync_capture_cell(ctx, cell, val), to: Coercion
  defdelegate await(val), to: Coercion
  defdelegate await(ctx, val), to: Coercion

  # --- Variables ---
  defdelegate get_var(name_or_atom_idx), to: Variables
  defdelegate get_var(ctx, name_or_atom_idx), to: Variables
  defdelegate get_global(globals, name), to: Variables
  defdelegate get_global_undef(globals, name), to: Variables
  defdelegate get_var_undef(name_or_atom_idx), to: Variables
  defdelegate get_var_undef(ctx, name_or_atom_idx), to: Variables
  defdelegate push_atom_value(atom_idx), to: Variables
  defdelegate push_atom_value(ctx, atom_idx), to: Variables
  defdelegate private_symbol(name_or_atom_idx), to: Variables
  defdelegate private_symbol(ctx, name_or_atom_idx), to: Variables
  defdelegate get_var_ref(idx), to: Variables
  defdelegate get_var_ref(ctx, idx), to: Variables
  defdelegate get_var_ref_check(idx), to: Variables
  defdelegate get_var_ref_check(ctx, idx), to: Variables
  defdelegate get_capture(ctx, key), to: Variables
  defdelegate invoke_var_ref(idx, args), to: Variables
  defdelegate invoke_var_ref(ctx, idx, args), to: Variables
  defdelegate invoke_var_ref0(idx), to: Variables
  defdelegate invoke_var_ref0(ctx, idx), to: Variables
  defdelegate invoke_var_ref1(idx, arg0), to: Variables
  defdelegate invoke_var_ref1(ctx, idx, arg0), to: Variables
  defdelegate invoke_var_ref2(idx, arg0, arg1), to: Variables
  defdelegate invoke_var_ref2(ctx, idx, arg0, arg1), to: Variables
  defdelegate invoke_var_ref3(idx, arg0, arg1, arg2), to: Variables
  defdelegate invoke_var_ref3(ctx, idx, arg0, arg1, arg2), to: Variables
  defdelegate invoke_var_ref_check(idx, args), to: Variables
  defdelegate invoke_var_ref_check(ctx, idx, args), to: Variables
  defdelegate invoke_var_ref_check0(idx), to: Variables
  defdelegate invoke_var_ref_check0(ctx, idx), to: Variables
  defdelegate invoke_var_ref_check1(idx, arg0), to: Variables
  defdelegate invoke_var_ref_check1(ctx, idx, arg0), to: Variables
  defdelegate invoke_var_ref_check2(idx, arg0, arg1), to: Variables
  defdelegate invoke_var_ref_check2(ctx, idx, arg0, arg1), to: Variables
  defdelegate invoke_var_ref_check3(idx, arg0, arg1, arg2), to: Variables
  defdelegate invoke_var_ref_check3(ctx, idx, arg0, arg1, arg2), to: Variables
  defdelegate put_var_ref(idx, val), to: Variables
  defdelegate put_var_ref(ctx, idx, val), to: Variables
  defdelegate set_var_ref(idx, val), to: Variables
  defdelegate set_var_ref(ctx, idx, val), to: Variables
  defdelegate put_capture(ctx, key, val), to: Variables
  defdelegate set_capture(ctx, key, val), to: Variables
  defdelegate make_loc_ref(idx), to: Variables
  defdelegate make_loc_ref(ctx, idx), to: Variables
  defdelegate make_var_ref(ctx, atom_idx), to: Variables
  defdelegate make_arg_ref(idx), to: Variables
  defdelegate make_arg_ref(ctx, idx), to: Variables
  defdelegate get_ref_value(ref), to: Variables
  defdelegate get_ref_value(ctx, ref), to: Variables
  defdelegate put_ref_value(val, ref), to: Variables
  defdelegate put_ref_value(ctx, val, ref), to: Variables
  defdelegate make_var_ref_ref(ctx, idx), to: Variables

  # --- Objects ---
  defdelegate get_field(obj, key), to: Objects
  defdelegate get_array_el2(obj, idx), to: Objects
  defdelegate get_array_el2(ctx, obj, idx), to: Objects
  defdelegate get_private_field(ctx, obj, key), to: Objects
  defdelegate put_field(obj, key, val), to: Objects
  defdelegate put_field(ctx, obj, key_or_atom, val), to: Objects
  defdelegate put_array_el(obj, idx, val), to: Objects
  defdelegate put_array_el(ctx, obj, idx, val), to: Objects
  defdelegate define_array_el(obj, idx, val), to: Objects
  defdelegate define_array_el(ctx, obj, idx, val), to: Objects
  defdelegate define_field(obj, key, val), to: Objects
  defdelegate define_field(ctx, obj, key_or_atom, val), to: Objects
  defdelegate put_private_field(ctx, obj, key, val), to: Objects
  defdelegate define_private_field(ctx, obj, key, val), to: Objects
  defdelegate set_function_name(fun, name), to: Objects
  defdelegate set_function_name(ctx, fun, name), to: Objects
  defdelegate set_function_name_atom(fun, atom_idx), to: Objects
  defdelegate set_function_name_atom(ctx, fun, atom_idx), to: Objects
  defdelegate set_function_name_computed(fun, name_val), to: Objects
  defdelegate set_function_name_computed(ctx, fun, name_val), to: Objects
  defdelegate set_home_object(method, target), to: Objects
  defdelegate set_home_object(ctx, method, target), to: Objects
  defdelegate get_super(func), to: Objects
  defdelegate get_super(ctx, func), to: Objects
  defdelegate copy_data_properties(target, source), to: Objects
  defdelegate copy_data_properties(ctx, target, source), to: Objects
  defdelegate new_object(), to: Objects
  defdelegate new_object(ctx), to: Objects
  defdelegate array_from(list), to: Objects
  defdelegate array_from(ctx, list), to: Objects
  defdelegate delete_property(obj, key), to: Objects
  defdelegate delete_property(ctx, obj, key), to: Objects
  defdelegate set_proto(obj, proto), to: Objects
  defdelegate set_proto(ctx, obj, proto), to: Objects

  # --- Functions ---
  defdelegate construct_runtime(ctor, new_target, args), to: Functions
  defdelegate construct_runtime(ctx, ctor, new_target, args), to: Functions
  defdelegate init_ctor(ctx), to: Functions
  defdelegate invoke_runtime(fun, args), to: Functions
  defdelegate invoke_runtime(ctx, fun, args), to: Functions
  defdelegate invoke_method_runtime(fun, this_obj, args), to: Functions
  defdelegate invoke_method_runtime(ctx, fun, this_obj, args), to: Functions
  defdelegate invoke_tail_method(ctx, fun, this_obj, args), to: Functions
  defdelegate define_class(ctor, parent_ctor, atom_idx), to: Functions
  defdelegate define_class(ctx, ctor, parent_ctor, atom_idx), to: Functions
  defdelegate define_method(target, method, name, flags), to: Functions
  defdelegate define_method(ctx, target, method, name_or_atom, flags), to: Functions
  defdelegate define_method_computed(target, method, field_name, flags), to: Functions
  defdelegate define_method_computed(ctx, target, method, field_name, flags), to: Functions
  defdelegate add_brand(target, brand), to: Functions
  defdelegate add_brand(ctx, target, brand), to: Functions
  defdelegate check_brand(ctx, obj, brand), to: Functions
  defdelegate throw_error(ctx, atom_idx, reason), to: Functions
  defdelegate throw_error_message(name, reason), to: Functions
  defdelegate apply_super(fun, new_target, args), to: Functions
  defdelegate apply_super(ctx, fun, new_target, args), to: Functions
  defdelegate push_this(), to: Functions
  defdelegate push_this(ctx), to: Functions
  defdelegate special_object(type), to: Functions
  defdelegate special_object(ctx, type), to: Functions
  defdelegate update_this(this_val), to: Functions
  defdelegate update_this(ctx, this_val), to: Functions
  defdelegate instanceof(obj, ctor), to: Functions
  defdelegate get_length(obj), to: Functions
  defdelegate import_module(specifier), to: Functions
  defdelegate import_module(ctx, specifier), to: Functions

  # --- Iterators ---
  defdelegate for_of_start(obj), to: Iterators
  defdelegate for_of_start(ctx, obj), to: Iterators
  defdelegate for_of_next(next_fn, iter), to: Iterators
  defdelegate for_of_next(ctx, next_fn, iter), to: Iterators
  defdelegate for_in_start(obj), to: Iterators
  defdelegate for_in_start(ctx, obj), to: Iterators
  defdelegate for_in_next(iter), to: Iterators
  defdelegate for_in_next(ctx, iter), to: Iterators
  defdelegate iterator_close(iter), to: Iterators
  defdelegate iterator_close(ctx, iter), to: Iterators
  defdelegate collect_iterator(iter, next_fn), to: Iterators
  defdelegate collect_iterator(ctx, iter, next_fn), to: Iterators
  defdelegate append_spread(arr, idx, obj), to: Iterators
  defdelegate append_spread(ctx, arr, idx, obj), to: Iterators
  defdelegate rest(ctx, start_idx), to: Iterators

  # --- Misc ---
  def undefined_or_null?(val), do: val == :undefined or val == nil

  def set_name_computed(_ctx \\ nil, fun, name_val),
    do: Objects.set_function_name_computed(fun, name_val)
end
