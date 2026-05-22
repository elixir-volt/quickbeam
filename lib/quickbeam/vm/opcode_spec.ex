defmodule QuickBEAM.VM.OpcodeSpec do
  @moduledoc "Authoritative opcode metadata facade used by decoding, analysis, and compiler dispatch."

  alias QuickBEAM.VM.Opcodes

  @type opcode :: non_neg_integer()
  @type opcode_name :: atom()

  @families %{
    call: [:call, :call0, :call1, :call2, :call3],
    get_slot: [
      :get_arg,
      :get_arg0,
      :get_arg1,
      :get_arg2,
      :get_arg3,
      :get_loc,
      :get_loc0,
      :get_loc1,
      :get_loc2,
      :get_loc3,
      :get_loc8
    ],
    put_slot: [
      :put_loc,
      :put_loc0,
      :put_loc1,
      :put_loc2,
      :put_loc3,
      :put_loc8,
      :put_arg,
      :put_arg0,
      :put_arg1,
      :put_arg2,
      :put_arg3
    ],
    set_slot: [
      :set_loc,
      :set_loc0,
      :set_loc1,
      :set_loc2,
      :set_loc3,
      :set_loc8,
      :set_arg,
      :set_arg0,
      :set_arg1,
      :set_arg2,
      :set_arg3
    ],
    false_branch: [:if_false, :if_false8],
    true_branch: [:if_true, :if_true8],
    goto: [:goto, :goto8, :goto16],
    finally_control: [:catch, :gosub, :goto, :goto8, :goto16]
  }

  @small_int_push %{
    push_minus1: -1,
    push_0: 0,
    push_1: 1,
    push_2: 2,
    push_3: 3,
    push_4: 4,
    push_5: 5,
    push_6: 6,
    push_7: 7
  }

  @call Map.fetch!(@families, :call)
  @get_slot Map.fetch!(@families, :get_slot)
  @put_slot Map.fetch!(@families, :put_slot)
  @set_slot Map.fetch!(@families, :set_slot)
  @small_int_push_names Map.keys(@small_int_push)

  def table, do: Opcodes.table()
  def all_opcodes, do: Opcodes.all_opcodes()
  def info(opcode), do: Opcodes.info(opcode)
  def num(name), do: Opcodes.num(name)
  def format_info(format), do: Opcodes.format_info(format)

  def name(opcode) do
    case info(opcode) do
      {name, _size, _pops, _pushes, _format} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, opcode}}
    end
  end

  def stack_effect(opcode) do
    case info(opcode) do
      {_name, _size, pops, pushes, _format} -> {:ok, {pops, pushes}}
      nil -> {:error, {:unknown_opcode, opcode}}
    end
  end

  def short_form_operands(opcode, arg_count), do: Opcodes.short_form_operands(opcode, arg_count)

  def family(name, family), do: name in Map.fetch!(@families, family)
  def family_members(family), do: Map.fetch!(@families, family)
  def small_int_push(name), do: Map.fetch(@small_int_push, name)
  def small_int_push_names, do: Map.keys(@small_int_push)

  def lowering_family(name)
      when name in [
             :push_i32,
             :push_i16,
             :push_i8,
             :push_true,
             :push_false,
             :null,
             :undefined,
             :push_empty_string,
             :push_bigint_i32,
             :push_atom_value,
             :push_this,
             :push_const,
             :push_const8,
             :fclosure,
             :fclosure8,
             :private_symbol,
             :dup,
             :dup1,
             :dup2,
             :dup3,
             :insert2,
             :insert3,
             :insert4,
             :drop,
             :nip,
             :nip1,
             :swap,
             :swap2,
             :rot3l,
             :rot3r,
             :rot4l,
             :rot5l,
             :perm3,
             :perm4,
             :perm5,
             :nop
           ], do: :stack

  def lowering_family(name)
      when name in [
             :get_loc0_loc1,
             :get_loc_check,
             :set_loc_uninitialized,
             :put_loc_check,
             :put_loc_check_init,
             :close_loc,
             :inc_loc,
             :dec_loc,
             :add_loc
           ], do: :locals

  def lowering_family(name)
      when name in [
             :call_constructor,
             :tail_call,
             :call_method,
             :tail_call_method,
             :apply,
             :apply_eval,
             :eval,
             :import,
             :return,
             :return_undef
           ], do: :calls

  def lowering_family(name)
      when name in [
             :object,
             :array_from,
             :regexp,
             :special_object,
             :set_name,
             :set_name_computed,
             :set_home_object,
             :get_super,
             :get_super_value,
             :put_super_value,
             :get_field,
             :get_field2,
             :put_field,
             :define_static_method,
             :define_field,
             :get_array_el,
             :get_array_el2,
             :put_array_el,
             :define_array_el,
             :append,
             :copy_data_properties,
             :set_proto,
             :check_ctor_return,
             :check_ctor,
             :to_object,
             :to_propkey,
             :to_propkey2,
             :get_length,
             :instanceof,
             :in,
             :delete,
             :get_private_field,
             :put_private_field,
             :define_private_field,
             :private_in
           ], do: :objects

  def lowering_family(name)
      when name in [
             :dec,
             :inc,
             :post_dec,
             :post_inc,
             :neg,
             :plus,
             :not,
             :lnot,
             :typeof,
             :is_undefined,
             :is_null,
             :typeof_is_undefined,
             :typeof_is_function,
             :mul,
             :div,
             :mod,
             :add,
             :sub,
             :shl,
             :sar,
             :shr,
             :lt,
             :lte,
             :gt,
             :gte,
             :instanceof,
             :in,
             :eq,
             :neq,
             :strict_eq,
             :strict_neq,
             :and,
             :xor,
             :or,
             :pow
           ], do: :arithmetic

  def lowering_family(name)
      when name in [
             :if_false,
             :if_true,
             :goto,
             :catch,
             :gosub,
             :ret,
             :nip_catch,
             :throw,
             :if_false8,
             :if_true8,
             :goto8,
             :goto16
           ], do: :control

  def lowering_family(name)
      when name in [
             :for_in_start,
             :for_of_start,
             :for_await_of_start,
             :for_in_next,
             :for_of_next,
             :iterator_check_object,
             :iterator_get_value_done,
             :iterator_close,
             :iterator_next,
             :iterator_call,
             :rest
           ], do: :iterators

  def lowering_family(name)
      when name in [
             :define_method,
             :define_method_computed,
             :define_class,
             :define_class_computed,
             :add_brand,
             :check_brand
           ], do: :classes

  def lowering_family(name)
      when name in [:initial_yield, :yield, :yield_star, :async_yield_star, :await],
      do: :generators

  def lowering_family(name)
      when name in [
             :with_get_var,
             :with_put_var,
             :with_delete_var,
             :with_make_ref,
             :with_get_ref,
             :with_get_ref_undef
           ], do: :with_scope

  def lowering_family(name)
      when name in [
             :get_var_undef,
             :get_var,
             :put_var,
             :put_var_init,
             :get_ref_value,
             :put_ref_value,
             :define_var,
             :check_define_var,
             :define_func,
             :delete_var,
             :make_loc_ref,
             :make_arg_ref,
             :make_var_ref_ref,
             :make_var_ref
           ], do: :globals

  def lowering_family(name) when name in @small_int_push_names, do: :stack

  def lowering_family(name) when name in @get_slot or name in @put_slot or name in @set_slot,
    do: :locals

  def lowering_family(name) when name in @call, do: :calls
  def lowering_family(_), do: nil
end
