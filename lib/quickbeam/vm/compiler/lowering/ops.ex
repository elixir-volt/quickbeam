defmodule QuickBEAM.VM.Compiler.Lowering.Ops do
  @moduledoc false

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.Analysis.Types, as: AnalysisTypes
  alias QuickBEAM.VM.Compiler.Lowering.Builder
  alias QuickBEAM.VM.Compiler.Lowering.Captures
  alias QuickBEAM.VM.Compiler.Lowering.State
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.{GlobalEnv}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Class, Private}

  @tdz :__tdz__

  def lower_instruction(
        {op, args},
        idx,
        next_entry,
        arg_count,
        state,
        stack_depths,
        constants,
        _entries,
        inline_targets
      ) do
    name = CFG.opcode_name(op)

    case {name, args} do
      {{:ok, :push_i32}, [value]} ->
        {:ok, State.push(state, Builder.integer(value))}

      {{:ok, :push_i16}, [value]} ->
        {:ok, State.push(state, Builder.integer(value))}

      {{:ok, :push_i8}, [value]} ->
        {:ok, State.push(state, Builder.integer(value))}

      {{:ok, :push_minus1}, [_]} ->
        {:ok, State.push(state, Builder.integer(-1))}

      {{:ok, :push_0}, [_]} ->
        {:ok, State.push(state, Builder.integer(0))}

      {{:ok, :push_1}, [_]} ->
        {:ok, State.push(state, Builder.integer(1))}

      {{:ok, :push_2}, [_]} ->
        {:ok, State.push(state, Builder.integer(2))}

      {{:ok, :push_3}, [_]} ->
        {:ok, State.push(state, Builder.integer(3))}

      {{:ok, :push_4}, [_]} ->
        {:ok, State.push(state, Builder.integer(4))}

      {{:ok, :push_5}, [_]} ->
        {:ok, State.push(state, Builder.integer(5))}

      {{:ok, :push_6}, [_]} ->
        {:ok, State.push(state, Builder.integer(6))}

      {{:ok, :push_7}, [_]} ->
        {:ok, State.push(state, Builder.integer(7))}

      {{:ok, :push_true}, []} ->
        {:ok, State.push(state, Builder.atom(true))}

      {{:ok, :push_false}, []} ->
        {:ok, State.push(state, Builder.atom(false))}

      {{:ok, :null}, []} ->
        {:ok, State.push(state, Builder.atom(nil))}

      {{:ok, :undefined}, []} ->
        {:ok, State.push(state, Builder.atom(:undefined))}

      {{:ok, :push_empty_string}, []} ->
        {:ok, State.push(state, Builder.literal(""))}

      {{:ok, :object}, []} ->
        {obj, state} =
          State.bind(
            state,
            Builder.temp_name(state.temp),
            Builder.remote_call(QuickBEAM.VM.Heap, :wrap, [Builder.literal(%{})])
          )

        {:ok, State.push(state, obj, :object)}

      {{:ok, :array_from}, [argc]} ->
        State.array_from_call(state, argc)

      {{:ok, :push_const}, [const_idx]} ->
        push_const(state, constants, arg_count, const_idx)

      {{:ok, :push_const8}, [const_idx]} ->
        push_const(state, constants, arg_count, const_idx)

      {{:ok, :fclosure}, [const_idx]} ->
        lower_fclosure(state, constants, arg_count, const_idx)

      {{:ok, :fclosure8}, [const_idx]} ->
        lower_fclosure(state, constants, arg_count, const_idx)

      {{:ok, :regexp}, []} ->
        State.regexp_literal(state)

      {{:ok, :private_symbol}, [atom_idx]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :private_symbol, [
             Builder.literal(Builder.atom_name(state, atom_idx))
           ]),
           :unknown
         )}

      {{:ok, :push_atom_value}, [atom_idx]} ->
        {:ok, State.push(state, Builder.literal(Builder.atom_name(state, atom_idx)), :string)}

      {{:ok, :push_this}, []} ->
        {:ok, State.push(state, State.compiler_call(state, :push_this, []), :object)}

      {{:ok, :special_object}, [type]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :special_object, [Builder.literal(type)]),
           special_object_type(type)
         )}

      {{:ok, :set_name}, [atom_idx]} ->
        State.set_name_atom(state, Builder.atom_name(state, atom_idx))

      {{:ok, :set_name_computed}, []} ->
        State.set_name_computed(state)

      {{:ok, :set_home_object}, []} ->
        State.set_home_object(state)

      {{:ok, :close_loc}, [slot_idx]} ->
        Captures.close_capture_cell(state, slot_idx)

      {{:ok, :get_var}, [atom_idx]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :get_var, [
             Builder.literal(Builder.atom_name(state, atom_idx))
           ])
         )}

      {{:ok, :get_var_undef}, [atom_idx]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :get_var_undef, [
             Builder.literal(Builder.atom_name(state, atom_idx))
           ])
         )}

      {{:ok, :get_super}, []} ->
        State.unary_call(state, RuntimeHelpers, :get_super)

      {{:ok, :get_arg}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg0}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg1}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg2}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg3}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc0}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc1}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc2}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc3}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc8}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok,
         %{
           state
           | stack: [State.slot_expr(state, slot1), State.slot_expr(state, slot0) | state.stack],
             stack_types: [
               State.slot_type(state, slot1),
               State.slot_type(state, slot0) | state.stack_types
             ]
         }}

      {{:ok, :get_loc_check}, [slot_idx]} ->
        lower_get_loc_check(state, slot_idx)

      {{:ok, name}, [idx]}
      when name in [:get_var_ref, :get_var_ref0, :get_var_ref1, :get_var_ref2, :get_var_ref3] ->
        {expr, state} = State.inline_get_var_ref(state, idx)
        {:ok, State.push(state, expr)}

      {{:ok, :get_var_ref_check}, [idx]} ->
        {expr, state} = State.inline_get_var_ref(state, idx)
        {:ok, State.push(state, expr)}

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, State.put_uninitialized_slot(state, slot_idx, Builder.atom(@tdz))}

      {{:ok, :define_var}, [atom_idx, _scope]} ->
        {:ok,
         State.update_ctx(
           state,
           Builder.remote_call(GlobalEnv, :define_var, [
             State.ctx_expr(state),
             Builder.literal(atom_idx)
           ])
         )}

      {{:ok, :check_define_var}, [atom_idx, _scope]} ->
        {:ok,
         State.update_ctx(
           state,
           Builder.remote_call(GlobalEnv, :check_define_var, [
             State.ctx_expr(state),
             Builder.literal(atom_idx)
           ])
         )}

      {{:ok, :put_var}, [atom_idx]} ->
        lower_put_var(state, atom_idx)

      {{:ok, :put_var_init}, [atom_idx]} ->
        lower_put_var(state, atom_idx)

      {{:ok, :define_func}, [atom_idx, _flags]} ->
        lower_put_var(state, atom_idx)

      {{:ok, :put_loc}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc8}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, name}, [idx]}
      when name in [
             :put_var_ref,
             :put_var_ref0,
             :put_var_ref1,
             :put_var_ref2,
             :put_var_ref3,
             :put_var_ref_check,
             :put_var_ref_check_init
           ] ->
        lower_put_var_ref(state, idx)

      {{:ok, :put_loc_check}, [slot_idx]} ->
        lower_put_loc_check(state, slot_idx)

      {{:ok, :put_loc_check_init}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :set_loc}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc8}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, name}, [idx]}
      when name in [:set_var_ref, :set_var_ref0, :set_var_ref1, :set_var_ref2, :set_var_ref3] ->
        lower_set_var_ref(state, idx)

      {{:ok, :dup}, []} ->
        State.duplicate_top(state)

      {{:ok, :dup1}, []} ->
        lower_dup1(state)

      {{:ok, :dup2}, []} ->
        State.duplicate_top_two(state)

      {{:ok, :dup3}, []} ->
        lower_dup3(state)

      {{:ok, :insert2}, []} ->
        State.insert_top_two(state)

      {{:ok, :insert3}, []} ->
        State.insert_top_three(state)

      {{:ok, :insert4}, []} ->
        lower_insert4(state)

      {{:ok, :drop}, []} ->
        State.drop_top(state)

      {{:ok, :nip}, []} ->
        lower_nip(state)

      {{:ok, :nip1}, []} ->
        lower_nip1(state)

      {{:ok, :swap}, []} ->
        State.swap_top(state)

      {{:ok, :swap2}, []} ->
        lower_swap2(state)

      {{:ok, :rot3l}, []} ->
        lower_rot3l(state)

      {{:ok, :rot3r}, []} ->
        lower_rot3r(state)

      {{:ok, :rot4l}, []} ->
        lower_rot4l(state)

      {{:ok, :rot5l}, []} ->
        lower_rot5l(state)

      {{:ok, :perm3}, []} ->
        State.permute_top_three(state)

      {{:ok, :perm4}, []} ->
        lower_perm4(state)

      {{:ok, :perm5}, []} ->
        lower_perm5(state)

      {{:ok, :neg}, []} ->
        State.unary_local_call(state, :op_neg)

      {{:ok, :plus}, []} ->
        State.unary_local_call(state, :op_plus)

      {{:ok, :not}, []} ->
        State.unary_call(state, RuntimeHelpers, :bit_not)

      {{:ok, :lnot}, []} ->
        State.unary_call(state, RuntimeHelpers, :lnot)

      {{:ok, :is_undefined}, []} ->
        State.unary_call(state, RuntimeHelpers, :undefined?)

      {{:ok, :is_null}, []} ->
        State.unary_call(state, RuntimeHelpers, :null?)

      {{:ok, :typeof_is_undefined}, []} ->
        State.unary_call(state, RuntimeHelpers, :typeof_is_undefined)

      {{:ok, :typeof_is_function}, []} ->
        State.unary_call(state, RuntimeHelpers, :typeof_is_function)

      {{:ok, :inc}, []} ->
        State.unary_call(state, RuntimeHelpers, :inc)

      {{:ok, :dec}, []} ->
        State.unary_call(state, RuntimeHelpers, :dec)

      {{:ok, :inc_loc}, [slot_idx]} ->
        State.inc_slot(state, slot_idx)

      {{:ok, :dec_loc}, [slot_idx]} ->
        State.dec_slot(state, slot_idx)

      {{:ok, :add_loc}, [slot_idx]} ->
        State.add_to_slot(state, slot_idx)

      {{:ok, :post_inc}, []} ->
        State.post_update(state, :post_inc)

      {{:ok, :post_dec}, []} ->
        State.post_update(state, :post_dec)

      {{:ok, :add}, []} ->
        State.binary_local_call(state, :op_add)

      {{:ok, :sub}, []} ->
        State.binary_local_call(state, :op_sub)

      {{:ok, :mul}, []} ->
        State.binary_local_call(state, :op_mul)

      {{:ok, :div}, []} ->
        State.binary_local_call(state, :op_div)

      {{:ok, :mod}, []} ->
        State.binary_call(state, Values, :mod)

      {{:ok, :pow}, []} ->
        State.binary_call(state, Values, :pow)

      {{:ok, :band}, []} ->
        State.binary_call(state, Values, :band)

      {{:ok, :bor}, []} ->
        State.binary_call(state, Values, :bor)

      {{:ok, :bxor}, []} ->
        State.binary_call(state, Values, :bxor)

      {{:ok, :shl}, []} ->
        State.binary_call(state, Values, :shl)

      {{:ok, :sar}, []} ->
        State.binary_call(state, Values, :sar)

      {{:ok, :shr}, []} ->
        State.binary_call(state, Values, :shr)

      {{:ok, :typeof}, []} ->
        State.unary_call(state, Values, :typeof)

      {{:ok, :instanceof}, []} ->
        State.binary_call(state, RuntimeHelpers, :instanceof)

      {{:ok, :in}, []} ->
        State.in_call(state)

      {{:ok, :delete}, []} ->
        State.delete_call(state)

      {{:ok, :get_length}, []} ->
        State.get_length_call(state)

      {{:ok, :get_array_el}, []} ->
        State.binary_call(state, QuickBEAM.VM.ObjectModel.Put, :get_element)

      {{:ok, :get_array_el2}, []} ->
        State.get_array_el2(state)

      {{:ok, :get_field}, [atom_idx]} ->
        State.get_field_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :get_field2}, [atom_idx]} ->
        State.get_field2(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :put_field}, [atom_idx]} ->
        State.put_field_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :define_field}, [atom_idx]} ->
        State.define_field_name_call(state, Builder.literal(Builder.atom_name(state, atom_idx)))

      {{:ok, :define_method}, [atom_idx, flags]} ->
        State.define_method_call(state, Builder.atom_name(state, atom_idx), flags)

      {{:ok, :define_method_computed}, [flags]} ->
        State.define_method_computed_call(state, flags)

      {{:ok, :define_class}, [atom_idx, _flags]} ->
        State.define_class_call(state, atom_idx)

      {{:ok, :define_class_computed}, [atom_idx, _flags]} ->
        lower_define_class_computed(state, atom_idx)

      {{:ok, :set_proto}, []} ->
        lower_set_proto(state)

      {{:ok, :get_super_value}, []} ->
        lower_get_super_value(state)

      {{:ok, :put_super_value}, []} ->
        lower_put_super_value(state)

      {{:ok, :check_ctor_return}, []} ->
        lower_check_ctor_return(state)

      {{:ok, :init_ctor}, []} ->
        lower_init_ctor(state)

      {{:ok, :put_array_el}, []} ->
        State.put_array_el_call(state)

      {{:ok, :define_array_el}, []} ->
        State.define_array_el_call(state)

      {{:ok, :append}, []} ->
        State.append_call(state)

      {{:ok, :copy_data_properties}, [mask]} ->
        State.copy_data_properties_call(state, mask)

      {{:ok, :to_object}, []} ->
        {:ok, state}

      {{:ok, :to_propkey}, []} ->
        {:ok, state}

      {{:ok, :to_propkey2}, []} ->
        {:ok, state}

      {{:ok, :check_ctor}, []} ->
        {:ok, state}

      {{:ok, :lt}, []} ->
        State.binary_local_call(state, :op_lt)

      {{:ok, :lte}, []} ->
        State.binary_local_call(state, :op_lte)

      {{:ok, :gt}, []} ->
        State.binary_local_call(state, :op_gt)

      {{:ok, :gte}, []} ->
        State.binary_local_call(state, :op_gte)

      {{:ok, :eq}, []} ->
        State.binary_local_call(state, :op_eq)

      {{:ok, :neq}, []} ->
        State.binary_local_call(state, :op_neq)

      {{:ok, :strict_eq}, []} ->
        State.binary_local_call(state, :op_strict_eq)

      {{:ok, :strict_neq}, []} ->
        State.binary_local_call(state, :op_strict_neq)

      {{:ok, :for_in_start}, []} ->
        lower_for_in_start(state)

      {{:ok, :for_in_next}, []} ->
        lower_for_in_next(state)

      {{:ok, :for_of_start}, []} ->
        lower_for_of_start(state)

      {{:ok, :for_of_next}, [iter_idx]} ->
        lower_for_of_next(state, iter_idx)

      {{:ok, :iterator_close}, []} ->
        lower_iterator_close(state)

      {{:ok, :add_brand}, []} ->
        State.add_brand(state)

      {{:ok, :check_brand}, []} ->
        lower_check_brand(state)

      {{:ok, :get_private_field}, []} ->
        lower_get_private_field(state)

      {{:ok, :put_private_field}, []} ->
        lower_put_private_field(state)

      {{:ok, :define_private_field}, []} ->
        lower_define_private_field(state)

      {{:ok, :private_in}, []} ->
        lower_private_in(state)

      {{:ok, :nip_catch}, []} ->
        State.nip_catch(state)

      {{:ok, :throw}, []} ->
        State.throw_top(state)

      {{:ok, :throw_error}, [atom_idx, reason]} ->
        lower_throw_error(state, atom_idx, reason)

      {{:ok, :call_constructor}, [argc]} ->
        State.invoke_constructor_call(state, argc)

      {{:ok, :call}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call0}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call1}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call2}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call3}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :tail_call}, [argc]} ->
        State.invoke_tail_call(state, argc)

      {{:ok, :call_method}, [argc]} ->
        State.invoke_method_call(state, argc)

      {{:ok, :tail_call_method}, [argc]} ->
        State.invoke_tail_method_call(state, argc)

      {{:ok, :make_loc_ref}, [idx]} ->
        lower_make_loc_ref(state, idx)

      {{:ok, :make_arg_ref}, [idx]} ->
        lower_make_arg_ref(state, idx)

      {{:ok, :make_var_ref}, [idx]} ->
        lower_make_loc_ref(state, idx)

      {{:ok, :make_var_ref_ref}, [idx]} ->
        lower_make_var_ref_ref(state, idx)

      {{:ok, :get_ref_value}, []} ->
        lower_get_ref_value(state)

      {{:ok, :put_ref_value}, []} ->
        lower_put_ref_value(state)

      {{:ok, :rest}, [start_idx]} ->
        lower_rest(state, start_idx)

      {{:ok, :push_bigint_i32}, [value]} ->
        {:ok, State.push(state, Builder.tuple_expr([Builder.atom(:bigint), Builder.integer(value)]))}

      {{:ok, :delete_var}, [_atom_idx]} ->
        {:ok, State.push(state, Builder.atom(true), :boolean)}

      {{:ok, :is_undefined_or_null}, []} ->
        lower_is_undefined_or_null(state)

      {{:ok, :if_false}, [target]} ->
        State.branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_false8}, [target]} ->
        State.branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_true}, [target]} ->
        State.branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :if_true8}, [target]} ->
        State.branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :goto}, [target]} ->
        lower_goto(state, target, stack_depths, inline_targets)

      {{:ok, :goto8}, [target]} ->
        lower_goto(state, target, stack_depths, inline_targets)

      {{:ok, :goto16}, [target]} ->
        lower_goto(state, target, stack_depths, inline_targets)

      {{:ok, :return}, []} ->
        State.return_top(state)

      {{:ok, :return_undef}, []} ->
        {:done, state.body ++ [Builder.atom(:undefined)]}

      {{:ok, :nop}, []} ->
        {:ok, state}

      # ── Generators / async ──

      {{:ok, :initial_yield}, []} ->
        lower_initial_yield(state, next_entry, stack_depths)

      {{:ok, :yield}, []} ->
        lower_yield(state, next_entry, stack_depths)

      {{:ok, :yield_star}, []} ->
        lower_yield_star(state, next_entry, stack_depths)

      {{:ok, :async_yield_star}, []} ->
        lower_yield_star(state, next_entry, stack_depths)

      {{:ok, :await}, []} ->
        lower_await(state)

      {{:ok, :return_async}, []} ->
        lower_return_async(state)

      {{:ok, :gosub}, [target]} ->
        # gosub is used for finally blocks — the block at target is
        # the finally body.  We inline it as a direct call since
        # the compiler already duplicates finally blocks via CFG.
        State.goto(state, target, stack_depths)

      {{:ok, :ret}, []} ->
        # ret returns from a gosub.  In the compiler's block model
        # the finally body falls through to the next block, so ret
        # is a no-op terminal.
        {:done, state.body ++ [Builder.atom(:undefined)]}

      {{:ok, :catch}, [_target]} ->
        # catch pushes catch offset — the compiler handles try/catch
        # via BEAM exceptions; push a dummy offset for nip_catch.
        {:ok, State.push(state, Builder.integer(0))}

      # ── eval / apply / import ──

      {{:ok, :eval}, [argc | _scope_args]} ->
        with {:ok, args, _types, state} <- State.pop_n_typed(state, argc + 1) do
          [eval_ref | call_args] = Enum.reverse(args)
          State.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_runtime, [
              State.ctx_expr(state), eval_ref, Builder.list_expr(call_args)
            ])
          )
        end

      {{:ok, :apply_eval}, [_scope_idx]} ->
        with {:ok, arg_array, state} <- State.pop(state),
             {:ok, fun, state} <- State.pop(state) do
          State.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_runtime, [
              State.ctx_expr(state),
              fun,
              Builder.remote_call(QuickBEAM.VM.Heap, :to_list, [arg_array])
            ])
          )
        end

      {{:ok, :apply}, [magic]} ->
        with {:ok, arg_array, state} <- State.pop(state),
             {:ok, this_obj, state} <- State.pop(state),
             {:ok, fun, state} <- State.pop(state) do
          expr =
            if magic == 1 do
              State.compiler_call(state, :construct_runtime, [
                fun, this_obj,
                Builder.remote_call(QuickBEAM.VM.Heap, :to_list, [arg_array])
              ])
            else
              Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_method_runtime, [
                State.ctx_expr(state), fun, this_obj,
                Builder.remote_call(QuickBEAM.VM.Heap, :to_list, [arg_array])
              ])
            end
          State.effectful_push(state, expr)
        end

      {{:ok, :import}, []} ->
        with {:ok, _meta, state} <- State.pop(state),
             {:ok, specifier, state} <- State.pop(state) do
          State.effectful_push(
            state,
            State.compiler_call(state, :import_module, [specifier])
          )
        end

      # ── with statement ──

      {{:ok, name}, [atom_idx, _target, _is_with]}
      when name in [:with_get_var, :with_get_ref, :with_get_ref_undef] ->
        with {:ok, obj, _type, state} <- State.pop_typed(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          val = Builder.remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [obj, key])
          case name do
            :with_get_var -> {:ok, State.push(state, val)}
            :with_get_ref -> {:ok, state |> State.push(obj) |> State.push(val)}
            :with_get_ref_undef -> {:ok, state |> State.push(Builder.atom(:undefined)) |> State.push(val)}
          end
        end

      {{:ok, :with_put_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state),
             {:ok, val, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          {:ok, %{state | body: state.body ++
            [Builder.remote_call(QuickBEAM.VM.ObjectModel.Put, :put, [obj, key, val])]}}
        end

      {{:ok, :with_delete_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          State.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.ObjectModel.Delete, :delete_property, [obj, key])
          )
        end

      {{:ok, :with_make_ref}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          {:ok, state |> State.push(obj) |> State.push(key)}
        end

      # ── Async iterators ──

      {{:ok, :for_await_of_start}, []} ->
        with {:ok, obj, _type, state} <- State.pop_typed(state) do
          State.effectful_push(state, State.compiler_call(state, :for_of_start, [obj]))
        end

      {{:ok, :iterator_next}, []} ->
        with {:ok, iter, state} <- State.pop(state) do
          next_fn = Builder.remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [iter, Builder.literal("next")])
          State.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.Runtime, :call_callback, [next_fn, Builder.list_expr([])])
          )
        end

      {{:ok, :iterator_call}, [_method]} ->
        with {:ok, iter, state} <- State.pop(state) do
          {:ok, %{state | body: state.body ++
            [State.compiler_call(state, :iterator_close, [iter])]}}
        end

      {{:ok, :iterator_check_object}, []} ->
        {:ok, state}

      {{:ok, :iterator_get_value_done}, []} ->
        with {:ok, result, state} <- State.pop(state) do
          done = Builder.remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [result, Builder.literal("done")])
          value = Builder.remote_call(QuickBEAM.VM.ObjectModel.Get, :get, [result, Builder.literal("value")])
          {:ok, state |> State.push(done) |> State.push(value)}
        end

      {{:ok, :invalid}, _} ->
        {:error, {:unsupported_opcode, :invalid}}

      {{:error, _} = error, _} ->
        error

      {{:ok, name}, _} ->
        {:error, {:unsupported_opcode, name}}
    end
  end

  defp lower_for_in_start(state) do
    with {:ok, obj, _type, state} <- State.pop_typed(state) do
      {:ok, State.push(state, State.compiler_call(state, :for_in_start, [obj]), :unknown)}
    end
  end

  defp lower_for_in_next(state) do
    case State.bind_stack_entry(state, 0) do
      {:ok, state, iter} ->
        {result, state} =
          State.bind(
            state,
            Builder.temp_name(state.temp),
            State.compiler_call(state, :for_in_next, [iter])
          )

        state = %{
          state
          | stack: List.replace_at(state.stack, 0, Builder.tuple_element(result, 3)),
            stack_types: List.replace_at(state.stack_types, 0, :unknown)
        }

        state = State.push(state, Builder.tuple_element(result, 2), :unknown)
        state = State.push(state, Builder.tuple_element(result, 1), :boolean)
        {:ok, state}

      :error ->
        {:error, :for_in_state_missing}
    end
  end

  defp lower_for_of_start(state) do
    with {:ok, obj, _type, state} <- State.pop_typed(state) do
      {pair, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          State.compiler_call(state, :for_of_start, [obj])
        )

      state = State.push(state, Builder.tuple_element(pair, 1), :object)
      state = State.push(state, Builder.tuple_element(pair, 2), :function)
      state = State.push(state, Builder.integer(0), :integer)
      {:ok, state}
    end
  end

  defp lower_for_of_next(state, iter_idx) do
    with {:ok, state, next_fn} <- State.bind_stack_entry(state, iter_idx + 1),
         {:ok, state, iter_obj} <- State.bind_stack_entry(state, iter_idx + 2) do
      {result, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          State.compiler_call(state, :for_of_next, [next_fn, iter_obj])
        )

      state = %{
        state
        | stack: List.replace_at(state.stack, iter_idx + 2, Builder.tuple_element(result, 3)),
          stack_types: List.replace_at(state.stack_types, iter_idx + 2, :object)
      }

      state = State.push(state, Builder.tuple_element(result, 2), :unknown)
      state = State.push(state, Builder.tuple_element(result, 1), :boolean)
      {:ok, state}
    else
      :error -> {:error, {:for_of_state_missing, iter_idx}}
    end
  end

  defp lower_iterator_close(state) do
    with {:ok, _catch_offset, _catch_type, state} <- State.pop_typed(state),
         {:ok, _next_fn, _next_type, state} <- State.pop_typed(state),
         {:ok, iter_obj, _iter_type, state} <- State.pop_typed(state) do
      {:ok,
       %{state | body: state.body ++ [State.compiler_call(state, :iterator_close, [iter_obj])]}}
    end
  end

  defp lower_fclosure(state, constants, arg_count, const_idx) do
    case Enum.at(constants, const_idx) do
      %QuickBEAM.VM.Bytecode.Function{closure_vars: []} = fun ->
        {:ok, State.push(state, Builder.literal(fun), AnalysisTypes.function_type(fun))}

      %QuickBEAM.VM.Bytecode.Function{} = fun ->
        with {:ok, state, entries} <-
               lower_closure_entries(state, arg_count, fun.closure_vars, []) do
          closure =
            Builder.tuple_expr([
              Builder.atom(:closure),
              Builder.map_expr(Enum.reverse(entries)),
              Builder.literal(fun)
            ])

          {:ok, State.push(state, closure, AnalysisTypes.function_type(fun))}
        end

      nil ->
        {:error, {:unsupported_const, const_idx}}

      other ->
        {:error, {:unsupported_fclosure_const, const_idx, other}}
    end
  end

  defp lower_closure_entries(state, _arg_count, [], acc), do: {:ok, state, acc}

  defp lower_closure_entries(
         state,
         arg_count,
         [%{closure_type: 2, var_idx: idx} = cv | rest],
         acc
       ) do
    {parent_ref, state} =
      State.bind(
        state,
        Builder.temp_name(state.temp),
        Builder.remote_call(QuickBEAM.VM.Compiler.RuntimeHelpers, :get_var_ref, [State.ctx_expr(state), Builder.literal(idx)])
      )

    {cell, state} =
      State.bind(
        state,
        Builder.temp_name(state.temp),
        State.compiler_call(state, :ensure_capture_cell, [parent_ref, parent_ref])
      )

    key = Builder.literal({cv.closure_type, cv.var_idx})
    lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
  end

  defp lower_closure_entries(state, arg_count, [cv | rest], acc) do
    with {:ok, slot_idx} <- closure_slot_index(arg_count, cv),
         {:ok, state, cell} <- Captures.ensure_capture_cell(state, slot_idx) do
      key = Builder.literal({cv.closure_type, cv.var_idx})
      lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
    end
  end

  defp closure_slot_index(_arg_count, %{closure_type: 1, var_idx: idx}), do: {:ok, idx}
  defp closure_slot_index(arg_count, %{closure_type: 0, var_idx: idx}), do: {:ok, idx + arg_count}

  defp closure_slot_index(_arg_count, %{closure_type: 2, var_idx: idx}),
    do: {:error, {:closure_var_ref_not_supported, idx}}

  defp closure_slot_index(_arg_count, %{closure_type: type, var_idx: idx}),
    do: {:error, {:closure_type_not_supported, type, idx}}

  defp push_const(state, constants, arg_count, idx) do
    case Enum.at(constants, idx) do
      nil ->
        {:error, {:unsupported_const, idx}}

      value
      when is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
             is_nil(value) ->
        {:ok, State.push(state, Builder.literal(value))}

      :undefined ->
        {:ok, State.push(state, Builder.atom(:undefined), :undefined)}

      %QuickBEAM.VM.Bytecode.Function{} = fun when fun.closure_vars == [] ->
        {:ok, State.push(state, Builder.literal(fun), AnalysisTypes.function_type(fun))}

      %QuickBEAM.VM.Bytecode.Function{} ->
        lower_fclosure(state, constants, arg_count, idx)

      _ ->
        {:error, {:unsupported_const, idx}}
    end
  end

  defp lower_put_var(state, atom_idx) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      {:ok,
       State.update_ctx(
         state,
         Builder.remote_call(GlobalEnv, :put, [
           State.ctx_expr(state),
           Builder.literal(atom_idx),
           val
         ])
       )}
    end
  end

  defp lower_put_var_ref(state, idx) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++ [State.compiler_call(state, :put_var_ref, [Builder.literal(idx), val])]
       }}
    end
  end

  defp lower_set_var_ref(state, idx) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      State.effectful_push(
        state,
        State.compiler_call(state, :set_var_ref, [Builder.literal(idx), val])
      )
    end
  end

  defp lower_is_undefined_or_null(state) do
    with {:ok, expr, type, state} <- State.pop_typed(state) do
      result =
        case type do
          :undefined -> Builder.atom(true)
          :null -> Builder.atom(true)
          _ -> Builder.undefined_or_null_expr(expr)
        end

      {:ok, State.push(state, result, :boolean)}
    end
  end

  defp lower_goto(state, target, stack_depths, inline_targets) do
    if MapSet.member?(inline_targets, target) do
      {:inline_goto, target, state}
    else
      State.goto(state, target, stack_depths)
    end
  end

  defp lower_get_loc_check(state, slot_idx) do
    slot_expr = State.slot_expr(state, slot_idx)
    slot_type = State.slot_type(state, slot_idx)

    expr =
      if State.slot_initialized?(state, slot_idx) do
        slot_expr
      else
        State.compiler_call(state, :ensure_initialized_local!, [slot_expr])
      end

    {:ok, State.push(state, expr, slot_type)}
  end

  defp lower_put_loc_check(state, slot_idx) do
    wrapper =
      if State.slot_initialized?(state, slot_idx) do
        nil
      else
        :ensure_initialized_local!
      end

    State.assign_slot(state, slot_idx, false, wrapper)
  end

  # ── Stack manipulation helpers ──

  # dup1: [a, b | rest] → [a, b, a, b | rest]
  # Note: in QuickJS, dup1 duplicates the top 2 entries
  defp lower_dup1(state) do
    with {:ok, a, ta, state} <- State.pop_typed(state),
         {:ok, b, tb, state} <- State.pop_typed(state) do
      {b_bound, state} = State.bind(state, Builder.temp_name(state.temp), b)
      {a_bound, state} = State.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b_bound, a_bound, b_bound | state.stack],
           stack_types: [ta, tb, ta, tb | state.stack_types]
       }}
    end
  end

  # dup3: [a, b, c | rest] → [a, b, c, a, b, c | rest]
  defp lower_dup3(state) do
    with {:ok, a, ta, state} <- State.pop_typed(state),
         {:ok, b, tb, state} <- State.pop_typed(state),
         {:ok, c, tc, state} <- State.pop_typed(state) do
      {c_bound, state} = State.bind(state, Builder.temp_name(state.temp), c)
      {b_bound, state} = State.bind(state, Builder.temp_name(state.temp), b)
      {a_bound, state} = State.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b_bound, c_bound, a_bound, b_bound, c_bound | state.stack],
           stack_types: [ta, tb, tc, ta, tb, tc | state.stack_types]
       }}
    end
  end

  # insert4: [a, b, c, d | rest] → [a, b, c, d, a | rest]
  defp lower_insert4(state) do
    with {:ok, a, ta, state} <- State.pop_typed(state),
         {:ok, b, tb, state} <- State.pop_typed(state),
         {:ok, c, tc, state} <- State.pop_typed(state),
         {:ok, d, td, state} <- State.pop_typed(state) do
      {a_bound, state} = State.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b, c, d, a_bound | state.stack],
           stack_types: [ta, tb, tc, td, ta | state.stack_types]
       }}
    end
  end

  # nip: [a, b | rest] → [a | rest]
  defp lower_nip(%{stack: [a, _b | rest], stack_types: [ta, _tb | type_rest]} = state),
    do: {:ok, %{state | stack: [a | rest], stack_types: [ta | type_rest]}}

  defp lower_nip(_state), do: {:error, :stack_underflow}

  # nip1: [a, b, c | rest] → [a, b | rest]
  defp lower_nip1(
         %{stack: [a, b, _c | rest], stack_types: [ta, tb, _tc | type_rest]} = state
       ),
       do: {:ok, %{state | stack: [a, b | rest], stack_types: [ta, tb | type_rest]}}

  defp lower_nip1(_state), do: {:error, :stack_underflow}

  # swap2: [a, b, c, d | rest] → [c, d, a, b | rest]
  defp lower_swap2(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [c, d, a, b | rest], stack_types: [tc, td, ta, tb | type_rest]}}

  defp lower_swap2(_state), do: {:error, :stack_underflow}

  # rot3l: [a, b, c | rest] → [c, a, b | rest] (rotate left: bottom goes to top)
  defp lower_rot3l(
         %{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state
       ),
       do: {:ok, %{state | stack: [c, a, b | rest], stack_types: [tc, ta, tb | type_rest]}}

  defp lower_rot3l(_state), do: {:error, :stack_underflow}

  # rot3r: [a, b, c | rest] → [b, c, a | rest] (rotate right: top goes to bottom)
  defp lower_rot3r(
         %{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state
       ),
       do: {:ok, %{state | stack: [b, c, a | rest], stack_types: [tb, tc, ta | type_rest]}}

  defp lower_rot3r(_state), do: {:error, :stack_underflow}

  # rot4l: [a, b, c, d | rest] → [d, a, b, c | rest]
  defp lower_rot4l(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{state | stack: [d, a, b, c | rest], stack_types: [td, ta, tb, tc | type_rest]}}

  defp lower_rot4l(_state), do: {:error, :stack_underflow}

  # rot5l: [a, b, c, d, e | rest] → [e, a, b, c, d | rest]
  defp lower_rot5l(
         %{
           stack: [a, b, c, d, e | rest],
           stack_types: [ta, tb, tc, td, te | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{
            state
            | stack: [e, a, b, c, d | rest],
              stack_types: [te, ta, tb, tc, td | type_rest]
          }}

  defp lower_rot5l(_state), do: {:error, :stack_underflow}

  # perm4: [a, b, c, d | rest] → [a, c, d, b | rest]
  defp lower_perm4(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{state | stack: [a, c, d, b | rest], stack_types: [ta, tc, td, tb | type_rest]}}

  defp lower_perm4(_state), do: {:error, :stack_underflow}

  # perm5: [a, b, c, d, e | rest] → [a, c, d, e, b | rest]
  defp lower_perm5(
         %{
           stack: [a, b, c, d, e | rest],
           stack_types: [ta, tb, tc, td, te | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{
            state
            | stack: [a, c, d, e, b | rest],
              stack_types: [ta, tc, td, te, tb | type_rest]
          }}

  defp lower_perm5(_state), do: {:error, :stack_underflow}

  # ── Private field helpers ──

  defp lower_get_private_field(state) do
    with {:ok, key, state} <- State.pop(state),
         {:ok, obj, state} <- State.pop(state) do
      State.effectful_push(
        state,
        State.compiler_call(state, :get_private_field, [obj, key])
      )
    end
  end

  defp lower_put_private_field(state) do
    with {:ok, key, state} <- State.pop(state),
         {:ok, val, state} <- State.pop(state),
         {:ok, obj, state} <- State.pop(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [State.compiler_call(state, :put_private_field, [obj, key, val])]
       }}
    end
  end

  defp lower_define_private_field(state) do
    with {:ok, val, state} <- State.pop(state),
         {:ok, key, state} <- State.pop(state),
         {:ok, obj, _obj_type, state} <- State.pop_typed(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [State.compiler_call(state, :define_private_field, [obj, key, val])],
           stack: [obj | state.stack],
           stack_types: [:object | state.stack_types]
       }}
    end
  end

  defp lower_check_brand(state) do
    with {:ok, state, brand} <- State.bind_stack_entry(state, 0),
         {:ok, state, obj} <- State.bind_stack_entry(state, 1) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [State.compiler_call(state, :check_brand, [obj, brand])]
       }}
    else
      :error -> {:error, :check_brand_state_missing}
    end
  end

  defp lower_private_in(state) do
    with {:ok, key, state} <- State.pop(state),
         {:ok, obj, state} <- State.pop(state) do
      {:ok,
       State.push(
         state,
         Builder.remote_call(Private, :has_field?, [obj, key]),
         :boolean
       )}
    end
  end

  # ── Class helpers ──

  defp lower_set_proto(state) do
    with {:ok, proto, state} <- State.pop(state),
         {:ok, obj, _obj_type, state} <- State.pop_typed(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [State.compiler_call(state, :set_proto, [obj, proto])],
           stack: [obj | state.stack],
           stack_types: [:object | state.stack_types]
       }}
    end
  end

  defp lower_get_super_value(state) do
    with {:ok, key, state} <- State.pop(state),
         {:ok, proto, state} <- State.pop(state),
         {:ok, this_obj, state} <- State.pop(state) do
      State.effectful_push(
        state,
        Builder.remote_call(Class, :get_super_value, [proto, this_obj, key])
      )
    end
  end

  defp lower_put_super_value(state) do
    with {:ok, val, state} <- State.pop(state),
         {:ok, key, state} <- State.pop(state),
         {:ok, proto_obj, state} <- State.pop(state),
         {:ok, this_obj, state} <- State.pop(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [Builder.remote_call(Class, :put_super_value, [proto_obj, this_obj, key, val])]
       }}
    end
  end

  defp lower_check_ctor_return(state) do
    with {:ok, val, state} <- State.pop(state) do
      {pair, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          Builder.remote_call(Class, :check_ctor_return, [val])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :unknown | state.stack_types]
       }}
    end
  end

  defp lower_init_ctor(state) do
    State.effectful_push(
      state,
      State.compiler_call(state, :init_ctor, []),
      :object
    )
  end

  defp lower_define_class_computed(state, atom_idx) do
    with {:ok, ctor, state} <- State.pop(state),
         {:ok, parent_ctor, state} <- State.pop(state),
         {:ok, _computed_name, state} <- State.pop(state) do
      {pair, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          State.compiler_call(state, :define_class, [
            ctor,
            parent_ctor,
            Builder.literal(atom_idx)
          ])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:object, :function | state.stack_types]
       }}
    end
  end

  # ── Ref creation helpers ──

  defp lower_make_loc_ref(state, idx) do
    State.effectful_push(
      state,
      State.compiler_call(state, :make_loc_ref, [Builder.literal(idx)]),
      :unknown
    )
  end

  defp lower_make_arg_ref(state, idx) do
    State.effectful_push(
      state,
      State.compiler_call(state, :make_arg_ref, [Builder.literal(idx)]),
      :unknown
    )
  end

  defp lower_make_var_ref_ref(state, idx) do
    State.effectful_push(
      state,
      State.compiler_call(state, :make_var_ref_ref, [Builder.literal(idx)]),
      :unknown
    )
  end

  defp lower_get_ref_value(state) do
    with {:ok, ref, state} <- State.pop(state) do
      State.effectful_push(
        state,
        State.compiler_call(state, :get_ref_value, [ref])
      )
    end
  end

  defp lower_put_ref_value(state) do
    with {:ok, val, state} <- State.pop(state),
         {:ok, ref, state} <- State.pop(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [State.compiler_call(state, :put_ref_value, [val, ref])]
       }}
    end
  end

  defp lower_rest(state, start_idx) do
    State.effectful_push(
      state,
      State.compiler_call(state, :rest, [Builder.literal(start_idx)]),
      :object
    )
  end

  defp lower_throw_error(state, atom_idx, reason) do
    {:done,
     state.body ++
       [
         State.compiler_call(state, :throw_error, [
           Builder.literal(atom_idx),
           Builder.literal(reason)
         ])
       ]}
  end

  defp special_object_type(2), do: :self_fun
  defp special_object_type(3), do: :function
  defp special_object_type(type) when type in [0, 1, 5, 6, 7], do: :object
  defp special_object_type(_), do: :unknown

  # ── Generator / async helpers ──

  defp lower_initial_yield(state, next_entry, stack_depths) do
    # initial_yield: yield :undefined, resume at next block
    yield_throw(state, Builder.atom(:undefined), next_entry, stack_depths)
  end

  defp lower_yield(state, next_entry, stack_depths) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      yield_throw(state, val, next_entry, stack_depths)
    end
  end

  defp lower_yield_star(state, next_entry, stack_depths) do
    # yield* delegates to an inner iterator — for now, treat same as yield
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      {:done,
       state.body ++
         [Builder.remote_call(:erlang, :throw, [
           Builder.tuple_expr([
             Builder.atom(:generator_yield_star),
             val,
             yield_continuation(state, next_entry, stack_depths)
           ])
         ])]}
    end
  end

  defp lower_await(state) do
    # await: synchronously resolve promise in BEAM VM
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      State.effectful_push(
        state,
        Builder.remote_call(QuickBEAM.VM.Compiler.RuntimeHelpers, :await, [
          State.ctx_expr(state),
          val
        ])
      )
    end
  end

  defp lower_return_async(state) do
    with {:ok, val, _state} <- State.pop(state) do
      {:done,
       state.body ++
         [Builder.remote_call(:erlang, :throw, [
           Builder.tuple_expr([Builder.atom(:generator_return), val])
         ])]}
    end
  end

  defp yield_throw(state, val, next_entry, stack_depths) do
    {:done,
     state.body ++
       [Builder.remote_call(:erlang, :throw, [
         Builder.tuple_expr([
           Builder.atom(:generator_yield),
           val,
           yield_continuation(state, next_entry, stack_depths)
         ])
       ])]}
  end

  defp yield_continuation(state, next_entry, stack_depths) do
    # The continuation is a fun(Arg) -> block_N(Ctx, Slots..., Arg, Captures...)
    # "Arg" is what next() passes — it becomes the yield return value
    # which the interpreter pushes as [false, arg | stack]
    # The "false" indicates "not a return", arg is the yielded-back value.
    arg_var = Builder.var("YieldArg")
    false_var = Builder.atom(false)

    ctx = State.ctx_expr(state)
    slots = State.current_slots(state)
    # The resumed block expects [false, arg | original_stack] on the stack
    stack = [false_var, arg_var | State.current_stack(state)]
    captures = State.current_capture_cells(state)

    expected_depth = Map.get(stack_depths, next_entry)

    if expected_depth && expected_depth == length(stack) do
      call =
        Builder.local_call(Builder.block_name(next_entry), [
          ctx | slots ++ stack ++ captures
        ])

      {:fun, 1, {:clauses, [{:clause, 1, [arg_var], [], [call]}]}}
    else
      # Stack depth mismatch — fall back to a noop continuation
      {:fun, 1, {:clauses, [{:clause, 1, [arg_var], [], [Builder.atom(:undefined)]}]}}
    end
  end
end
