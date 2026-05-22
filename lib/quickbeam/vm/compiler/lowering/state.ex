defmodule QuickBEAM.VM.Compiler.Lowering.State do
  @moduledoc "Lowering accumulator: tracks the operand stack, slot bindings, and emitted body forms during a block compilation."

  alias QuickBEAM.VM.Compiler.Lowering.{
    Atoms,
    Builder,
    Captures,
    Emit,
    Effects,
    Literals,
    Operators,
    Slots,
    Types
  }

  alias QuickBEAM.VM.Compiler.RuntimeABI
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.{Bindings, Constants}
  alias QuickBEAM.VM.GlobalEnvironment
  alias QuickBEAM.VM.ObjectModel.PropertyKey
  alias QuickBEAM.VM.Operands.CopyDataProperties

  defstruct [
    :body,
    :ctx,
    :slots,
    :slot_types,
    :slot_inits,
    :capture_cells,
    :stack,
    :stack_types,
    :temp,
    :locals,
    :closure_vars,
    :atoms,
    :arg_count,
    :strict_mode,
    :return_type,
    :frame_mode,
    :force_capture_slots
  ]

  # ── Construction ──

  @doc "Creates a lowering state with slot, stack, capture, and type metadata."
  def new(slot_count, stack_depth, opts \\ []) do
    frame_mode = Keyword.get(opts, :frame_mode, :args)

    slots =
      cond do
        slot_count == 0 ->
          %{}

        frame_mode == :tuple ->
          slots_tuple = Builder.var("Slots")

          Map.new(0..(slot_count - 1), fn idx ->
            {idx, Builder.tuple_element(slots_tuple, idx + 1)}
          end)

        true ->
          Map.new(0..(slot_count - 1), fn idx -> {idx, Builder.slot_var(idx)} end)
      end

    capture_cells =
      cond do
        slot_count == 0 ->
          %{}

        frame_mode == :tuple ->
          captures_tuple = Builder.var("Captures")

          Map.new(0..(slot_count - 1), fn idx ->
            {idx, Builder.tuple_element(captures_tuple, idx + 1)}
          end)

        true ->
          Map.new(0..(slot_count - 1), fn idx -> {idx, Builder.capture_var(idx)} end)
      end

    stack =
      if stack_depth == 0,
        do: [],
        else: Enum.map(0..(stack_depth - 1), &Builder.stack_var/1)

    arg_count = Keyword.get(opts, :arg_count, 0)
    strict_mode = Keyword.get(opts, :strict_mode, false)
    locals = Keyword.get(opts, :locals, [])

    %__MODULE__{
      body: [],
      ctx: Builder.ctx_var(),
      slots: slots,
      slot_types:
        Keyword.get(opts, :slot_types, Map.new(slots, fn {idx, _expr} -> {idx, :unknown} end)),
      slot_inits:
        Keyword.get(opts, :slot_inits, initial_slot_inits(slot_count, arg_count, locals)),
      capture_cells: capture_cells,
      stack: stack,
      stack_types: Keyword.get(opts, :stack_types, List.duplicate(:unknown, stack_depth)),
      temp: 0,
      locals: locals,
      closure_vars: Keyword.get(opts, :closure_vars, []),
      atoms: Keyword.get(opts, :atoms),
      arg_count: arg_count,
      strict_mode: strict_mode,
      return_type: Keyword.get(opts, :return_type, :unknown),
      frame_mode: frame_mode,
      force_capture_slots: Keyword.get(opts, :force_capture_slots, false)
    }
  end

  # ── Core state accessors and emitters ──

  @doc "Prepends one Erlang abstract-form expression to the accumulated body."

  def ctx_expr(%{ctx: ctx}), do: ctx
  def closure_vars_expr(%{closure_vars: cvs}), do: cvs

  def inline_get_var_ref(state, idx) do
    cvs = closure_vars_expr(state)

    case Enum.at(cvs, idx) do
      %{closure_type: type, var_idx: var_idx} ->
        key = Builder.literal({type, var_idx})

        {bound, state} =
          Emit.bind(
            state,
            Builder.temp_name(state.temp),
            abi_call(state, :get_capture, [key])
          )

        {bound, state}

      nil ->
        {Builder.atom(:undefined), state}
    end
  end

  def abi_call(state, fun, args),
    do: Builder.remote_call(RuntimeABI, fun, [ctx_expr(state) | args])

  def constant_call(state, fun, args),
    do: Builder.remote_call(Constants, fun, [ctx_expr(state) | args])

  @doc "Binds a new context expression and marks it as the current context."
  def update_ctx(state, expr) do
    {ctx, state} = Emit.bind(state, "Ctx#{state.temp}", expr)
    %{state | ctx: ctx}
  end

  def current_stack(state), do: state.stack

  def block_jump_call(state, target, stack_depths) do
    block_jump_call_values(
      target,
      stack_depths,
      ctx_expr(state),
      Slots.current_slots(state),
      state.stack,
      Slots.current_capture_cells(state),
      state.frame_mode
    )
  end

  @doc "Finishes the current block with an unconditional jump to another block."
  def goto(state, target, stack_depths) do
    with {:ok, call} <- block_jump_call(state, target, stack_depths) do
      {:done, Enum.reverse([call | state.body])}
    end
  end

  def branch(%{stack: stack}, idx, next_entry, target, sense, _stack_depths) when stack == [] do
    {:error, {:missing_branch_condition, idx, target, sense, next_entry}}
  end

  def branch(state, _idx, next_entry, target, sense, _stack_depths) when is_nil(next_entry) do
    {:error, {:missing_fallthrough_block, target, sense, state.body}}
  end

  def branch(state, _idx, next_entry, target, sense, stack_depths) do
    with {:ok, cond_expr, cond_type, state} <- Emit.pop_typed(state),
         {:ok, target_call} <- block_jump_call(state, target, stack_depths),
         {:ok, next_call} <- block_jump_call(state, next_entry, stack_depths) do
      truthy = Builder.branch_condition(cond_expr, cond_type)
      false_body = [target_call]
      true_body = [next_call]

      body =
        if sense do
          Enum.reverse([Builder.branch_case(truthy, true_body, false_body) | state.body])
        else
          Enum.reverse([Builder.branch_case(truthy, false_body, true_body) | state.body])
        end

      {:done, body}
    end
  end

  @doc "Lowers RegExp literal construction from pattern and flags stack values."
  def regexp_literal(state) do
    with {:ok, pattern, _pattern_type, state} <- Emit.pop_typed(state),
         {:ok, flags, _flags_type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, constant_call(state, :regexp_literal, [pattern, flags]), :unknown)}
    end
  end

  def add_to_slot(state, idx) do
    with {:ok, expr, expr_type, state} <- Emit.pop_typed(state) do
      {op_expr, result_type} =
        Operators.specialize_binary(
          :op_add,
          Slots.slot_expr(state, idx),
          Slots.slot_type(state, idx),
          expr,
          expr_type
        )

      update_slot(state, idx, op_expr, false, result_type)
    end
  end

  @doc "Lowers prefix increment of a local slot."
  def inc_slot(state, idx),
    do:
      update_slot(
        state,
        idx,
        abi_call(state, :inc, [Slots.slot_expr(state, idx)]),
        false,
        if(Slots.slot_type(state, idx) == :integer, do: :integer, else: :number)
      )

  @doc "Lowers prefix decrement of a local slot."
  def dec_slot(state, idx),
    do:
      update_slot(
        state,
        idx,
        abi_call(state, :dec, [Slots.slot_expr(state, idx)]),
        false,
        if(Slots.slot_type(state, idx) == :integer, do: :integer, else: :number)
      )

  @doc "Lowers property read and applies shaped-object fast paths when possible."
  def get_field_call(state, key_expr) do
    with {:ok, obj, type, state} <- Emit.pop_typed(state) do
      key_str = Literals.string(key_expr)

      case {type, key_str} do
        {{:shaped_object, _offsets, value_map}, key}
        when is_binary(key) and is_map_key(value_map, key) ->
          {:ok, Emit.push(state, Builder.local_call(:op_get_field, [obj, key_expr]))}

        {{:shaped_object, offsets}, key} when is_binary(key) and is_map_key(offsets, key) ->
          {:ok, Emit.push(state, Builder.local_call(:op_get_field, [obj, key_expr]))}

        _ ->
          {:ok, Emit.push(state, Builder.local_call(:op_get_field, [obj, key_expr]))}
      end
    end
  end

  @doc "Lowers property read while preserving both object and property result on the stack."
  def get_field2(state, key_expr) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      field = Builder.local_call(:op_get_field, [obj, key_expr])

      {:ok,
       %{
         state
         | stack: [field, obj | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  def get_array_el(state) do
    with {:ok, idx, _idx_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, abi_call(state, :get_array_el, [obj, idx]))}
    end
  end

  @doc "Lowers array element read while preserving receiver and element result on the stack."
  def get_array_el2(state) do
    with {:ok, idx, _idx_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          abi_call(state, :get_array_el2, [obj, idx])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  @doc "Lowers function-name assignment from an atom-table index."
  def set_name_atom(state, atom_name) do
    with {:ok, fun, fun_type, state} <- Emit.pop_typed(state) do
      {:ok,
       Emit.push(
         state,
         abi_call(state, :set_function_name, [fun, Builder.literal(atom_name)]),
         fun_type
       )}
    end
  end

  @doc "Lowers function-name assignment from a computed property value."
  def set_name_computed(state) do
    with {:ok, fun, fun_type, state} <- Emit.pop_typed(state),
         {:ok, name, name_type, state} <- Emit.pop_typed(state) do
      named = abi_call(state, :set_function_name_computed, [fun, name])

      {:ok,
       %{
         state
         | stack: [named, name | state.stack],
           stack_types: [fun_type, name_type | state.stack_types]
       }}
    end
  end

  @doc "Lowers method home-object attachment for `super` support."
  def set_home_object(state) do
    with {:ok, state, method} <- Emit.bind_stack_entry(state, 0),
         {:ok, state, target} <- Emit.bind_stack_entry(state, 1) do
      {:ok, Emit.emit(state, abi_call(state, :set_home_object, [method, target]))}
    else
      :error -> {:error, :set_home_object_state_missing}
    end
  end

  @doc "Lowers private brand attachment."
  def add_brand(state) do
    with {:ok, obj, state} <- Emit.pop(state),
         {:ok, brand, state} <- Emit.pop(state) do
      {:ok, Emit.emit(state, abi_call(state, :add_brand, [obj, brand]))}
    end
  end

  def put_field_call(state, key_expr) do
    with {:ok, val, _val_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      state = Effects.invalidate_shaped_aliases(state, obj)
      call = assignment_call_with_iterator_close(state, :put_field, [obj, key_expr, val])

      {:ok, Emit.emit(state, call)}
    end
  end

  @doc "Lowers object field definition with an atom-table field name."
  def define_field_name_call(state, key_expr) do
    with {:ok, val, _val_type, state} <- Emit.pop_typed(state),
         {:ok, obj, obj_type, state} <- Emit.pop_typed(state) do
      key_str = Literals.string(key_expr)
      {obj, state} = Emit.bind(state, Builder.temp_name(state.temp), obj)

      if key_str == "__proto__" do
        {:ok,
         state
         |> Emit.emit(abi_call(state, :define_field, [obj, key_expr, val]))
         |> Emit.push(obj, :object)}
      else
        new_type =
          case {obj_type, key_str} do
            {{:shaped_object, offsets}, k} when is_binary(k) ->
              new_offset = map_size(offsets)
              {:shaped_object, Map.put(offsets, k, new_offset)}

            _ ->
              :object
          end

        {:ok,
         state
         |> Emit.emit(abi_call(state, :define_field, [obj, key_expr, val]))
         |> Emit.push(obj, new_type)}
      end
    end
  end

  @doc "Lowers method/getter/setter definition with an atom-table name."
  def define_method_call(state, method_name, flags) do
    with {:ok, method, _method_type, state} <- Emit.pop_typed(state),
         {:ok, target, _target_type, state} <- Emit.pop_typed(state) do
      Effects.effectful_push(
        state,
        abi_call(state, :define_method, [
          target,
          method,
          Builder.literal(method_name),
          Builder.literal(flags)
        ]),
        :object
      )
    end
  end

  @doc "Lowers method/getter/setter definition with a computed name."
  def define_method_computed_call(state, flags) do
    with {:ok, method, state} <- Emit.pop(state),
         {:ok, field_name, state} <- Emit.pop(state),
         {:ok, target, state} <- Emit.pop(state) do
      Effects.effectful_push(
        state,
        abi_call(state, :define_method_computed, [
          target,
          method,
          field_name,
          Builder.literal(flags)
        ])
      )
    end
  end

  @doc "Lowers class definition and constructor/prototype wiring."
  def define_class_call(state, atom_idx) do
    with {:ok, ctor, state} <- Emit.pop(state),
         {:ok, parent_ctor, state} <- Emit.pop(state) do
      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          abi_call(state, :define_class, [ctor, parent_ctor, Builder.literal(atom_idx)])
        )

      ctor = Builder.tuple_element(pair, 2)
      ctor_type = Types.infer_expr_type(ctor)

      state =
        case class_binding_slot(state, atom_idx) do
          nil -> state
          slot_idx -> update_slot!(state, slot_idx, ctor, ctor_type)
        end

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), ctor | state.stack],
           stack_types: [:object, ctor_type | state.stack_types]
       }}
    end
  end

  @doc "Lowers array element assignment."
  def put_array_el_call(state) do
    with {:ok, val, _val_type, state} <- Emit.pop_typed(state),
         {:ok, idx, _idx_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      state = Effects.invalidate_shaped_aliases(state, obj)
      call = assignment_call_with_iterator_close(state, :put_array_el, [obj, idx, val])
      {:ok, Emit.emit(state, call)}
    end
  end

  @doc "Lowers array element definition with descriptor metadata."
  def define_array_el_call(state) do
    with {:ok, val, _val_type, state} <- Emit.pop_typed(state),
         {:ok, idx, _idx_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      {val_expr, state} = extract_bound_expr(state, val)

      {prop_key, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          Builder.remote_call(PropertyKey, :to_property_key, [idx])
        )

      state =
        update_ctx(state, Builder.remote_call(GlobalEnvironment, :refresh, [ctx_expr(state)]))

      val_expr = refresh_define_value_expr(state, val_expr)
      {val, state} = Emit.bind(state, Builder.temp_name(state.temp), val_expr)

      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          abi_call(state, :define_array_el, [obj, prop_key, val])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  defp extract_bound_expr(%{body: [{:match, _line, var, expr} | body]} = state, var),
    do: {expr, %{state | body: body}}

  defp extract_bound_expr(state, expr), do: {expr, state}

  defp refresh_define_value_expr(state, {:call, line, remote, [globals_expr, name]}) do
    case globals_expr do
      {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :map_get}},
       [{:atom, _, :globals}, _old_ctx]} ->
        {:call, line, remote, [context_globals_expr(state), name]}

      _ ->
        {:call, line, remote, [globals_expr, name]}
    end
  end

  defp refresh_define_value_expr(_state, expr), do: expr

  defp context_globals_expr(state) do
    {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :map_get}},
     [{:atom, 1, :globals}, ctx_expr(state)]}
  end

  @doc "Lowers conversion of an iterable or array-like value into an array object."
  def array_from_call(state, argc) do
    with {:ok, elems, _types, state} <- Emit.pop_n_typed(state, argc) do
      {:ok,
       Emit.push(
         state,
         abi_call(state, :array_from, [Builder.list_expr(Enum.reverse(elems))]),
         :object
       )}
    end
  end

  @doc "Lowers the JavaScript `in` operator."
  def in_call(state) do
    with {:ok, obj, _obj_type, state} <- Emit.pop_typed(state),
         {:ok, key, _key_type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, abi_call(state, :in_operator, [key, obj]), :boolean)}
    end
  end

  @doc "Lowers array/object spread append into an aggregate literal."
  def append_call(state) do
    with {:ok, obj, _obj_type, state} <- Emit.pop_typed(state),
         {:ok, idx, _idx_type, state} <- Emit.pop_typed(state),
         {:ok, arr, _arr_type, state} <- Emit.pop_typed(state) do
      {:ok,
       Emit.bind_pair(
         state,
         Builder.temp_name(state.temp),
         abi_call(state, :append_spread, [arr, idx, obj]),
         [:number, :object]
       )}
    end
  end

  @doc "Lowers object spread property copying."
  def copy_data_properties_call(state, mask) do
    %{target_idx: target_idx, source_idx: source_idx, exclude_idx: exclude_idx} =
      CopyDataProperties.decode(mask)

    with {:ok, state, target} <- Emit.bind_stack_entry(state, target_idx),
         {:ok, state, source} <- Emit.bind_stack_entry(state, source_idx),
         {:ok, state, exclude} <- Emit.bind_stack_entry(state, exclude_idx) do
      state = Effects.apply_effect(state, :copy_data_properties, target)

      {:ok,
       %{
         state
         | body: [
             abi_call(state, :copy_data_properties, [target, source, exclude]) | state.body
           ]
       }}
    else
      :error ->
        {:error, {:copy_data_properties_missing, mask, target_idx, source_idx, exclude_idx}}
    end
  end

  @doc "Lowers the JavaScript `delete` operator."
  def delete_call(state) do
    with {:ok, key, _key_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      state = Effects.invalidate_shaped_aliases(state, obj)
      Effects.effectful_push(state, abi_call(state, :delete_property, [obj, key]), :boolean)
    end
  end

  # ── Slots ──

  @doc "Lowers assignment to a local slot and returns the assigned value on the stack."
  def assign_slot(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, type, state} <- Emit.pop_typed(state) do
      expr =
        case wrapper do
          nil -> expr
          :ensure_initialized_local! -> abi_call(state, :ensure_initialized_local!, [expr])
        end

      {slot_expr, state} = Emit.bind(state, Builder.slot_name(idx, state.temp), expr)

      state = Slots.put_slot(state, idx, slot_expr, type)
      state = Captures.sync_capture_cell(state, idx, slot_expr)
      state = if keep?, do: Emit.push(state, slot_expr, type), else: state
      {:ok, state}
    end
  end

  @doc "Updates a local slot with an expression, initialization flag, and inferred type."
  def update_slot(state, idx, expr),
    do: update_slot(state, idx, expr, false, Types.infer_expr_type(expr))

  def update_slot(state, idx, expr, keep?),
    do: update_slot(state, idx, expr, keep?, Types.infer_expr_type(expr))

  def update_slot(state, idx, expr, keep?, type) do
    {slot_expr, state} =
      if keep? or not Types.pure_expr?(expr) or Captures.slot_captured?(state, idx) do
        Emit.bind(state, Builder.slot_name(idx, state.temp), expr)
      else
        {expr, state}
      end

    state = Slots.put_slot(state, idx, slot_expr, type)
    state = Captures.sync_capture_cell(state, idx, slot_expr)
    state = if keep?, do: Emit.push(state, slot_expr, type), else: state
    {:ok, state}
  end

  # ── Calls ──

  @doc "Lowers a JavaScript function call."
  def invoke_call(state, argc) do
    with {:ok, args, arg_types, state} <- Emit.pop_n_typed(state, argc),
         {:ok, fun, fun_type, state} <- Emit.pop_typed(state) do
      invoke_call_expr(state, fun, fun_type, Enum.reverse(args), Enum.reverse(arg_types))
    end
  end

  def invoke_constructor_call(state, argc, pc) do
    with {:ok, args, _arg_types, state} <- Emit.pop_n_typed(state, argc),
         {:ok, new_target, _new_target_type, state} <- Emit.pop_typed(state),
         {:ok, ctor, _ctor_type, state} <- Emit.pop_typed(state) do
      Effects.effectful_push(
        state,
        abi_call(state, :construct_runtime, [
          ctor,
          new_target,
          Builder.list_expr(Enum.reverse(args)),
          Builder.integer(pc)
        ]),
        :object
      )
    end
  end

  @doc "Lowers a tail-position JavaScript function call."
  def invoke_tail_call(state, argc) do
    with {:ok, args, arg_types, state} <- Emit.pop_n_typed(state, argc),
         {:ok, fun, fun_type, %{stack: [], stack_types: []} = state} <- Emit.pop_typed(state) do
      {:done, tail_call_expr(state, fun, fun_type, Enum.reverse(args), Enum.reverse(arg_types))}
    else
      {:ok, _fun, _fun_type, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  @doc "Lowers a JavaScript method call with receiver handling."
  def invoke_method_call(state, argc) do
    with {:ok, args, _arg_types, state} <- Emit.pop_n_typed(state, argc),
         {:ok, fun, fun_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Emit.pop_typed(state) do
      expr =
        abi_call(state, :invoke_method_runtime, [
          fun,
          obj,
          Builder.list_expr(Enum.reverse(args))
        ])

      {result, state} = Emit.bind(state, Builder.temp_name(state.temp), expr)

      state =
        update_ctx(
          state,
          Builder.remote_call(QuickBEAM.VM.GlobalEnvironment, :refresh, [ctx_expr(state)])
        )

      {:ok, Emit.push(state, result, function_return_type(fun_type, state.return_type))}
    end
  end

  @doc "Lowers a tail-position JavaScript method call with receiver handling."
  def invoke_tail_method_call(state, argc) do
    with {:ok, args, _arg_types, state} <- Emit.pop_n_typed(state, argc),
         {:ok, fun, _fun_type, state} <- Emit.pop_typed(state),
         {:ok, obj, _obj_type, %{stack: [], stack_types: []} = state} <- Emit.pop_typed(state) do
      expr =
        abi_call(state, :invoke_method_runtime, [
          fun,
          obj,
          Builder.list_expr(Enum.reverse(args))
        ])

      {:done, Enum.reverse([expr | state.body])}
    else
      {:ok, _obj, _obj_type, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  @doc "Builds block-call arguments from context, slots, stack, and captures."
  def block_jump_call_values(
        target,
        stack_depths,
        ctx,
        slots,
        stack,
        capture_cells,
        frame_mode \\ :args
      ) do
    expected_depth = Map.get(stack_depths, target)
    actual_depth = length(stack)

    cond do
      is_nil(expected_depth) ->
        {:error, {:unknown_block_target, target}}

      expected_depth != actual_depth ->
        {:error, {:stack_depth_mismatch, target, expected_depth, actual_depth}}

      true ->
        args =
          case frame_mode do
            :tuple -> [ctx, Builder.tuple_expr(slots), Builder.tuple_expr(capture_cells) | stack]
            _ -> [ctx | slots ++ stack ++ capture_cells]
          end

        {:ok, Builder.local_call(Builder.block_name(target), args)}
    end
  end

  @doc "Finishes the current block by returning the stack top."
  def return_top(state) do
    with {:ok, expr, _state} <- Emit.pop(state) do
      {:done, Enum.reverse([expr | state.body])}
    end
  end

  def throw_top(state) do
    with {:ok, expr, state} <- Emit.pop(state) do
      close_calls = active_iterator_close_calls(state)
      {:done, Enum.reverse([Builder.throw_js(expr) | close_calls ++ state.body])}
    end
  end

  defp assignment_call_with_iterator_close(state, fun, args) do
    case active_iterator_exprs(state) do
      [] ->
        abi_call(state, fun, args)

      iterators ->
        abi_call(state, :assignment_with_iterator_close, [
          Builder.literal(fun),
          Builder.list_expr(iterators) | args
        ])
    end
  end

  defp active_iterator_exprs(state) do
    state.stack
    |> Enum.zip(state.stack_types)
    |> active_iterator_exprs([])
  end

  defp active_iterator_exprs(
         [
           {_catch_marker, :integer},
           {_counter, :integer},
           {_next_fn, next_type},
           {_iter_obj, iter_type} | _rest
         ],
         acc
       )
       when next_type in [:function, :unknown] and iter_type in [:object, :unknown] do
    acc
  end

  defp active_iterator_exprs(
         [{_counter, :integer}, {_next_fn, next_type}, {iter_obj, iter_type} | rest],
         acc
       )
       when next_type in [:function, :unknown] and iter_type in [:object, :unknown] do
    active_iterator_exprs(rest, [iter_obj | acc])
  end

  defp active_iterator_exprs([_entry | rest], acc), do: active_iterator_exprs(rest, acc)
  defp active_iterator_exprs([], acc), do: Enum.reverse(acc)

  defp active_iterator_close_calls(state) do
    state.stack
    |> Enum.zip(state.stack_types)
    |> active_iterator_close_calls([])
  end

  defp active_iterator_close_calls(
         [
           {_catch_marker, :integer},
           {_counter, :integer},
           {_next_fn, next_type},
           {_iter_obj, iter_type} | _rest
         ],
         acc
       )
       when next_type in [:function, :unknown] and iter_type in [:object, :unknown] do
    acc
  end

  defp active_iterator_close_calls(
         [{_counter, :integer}, {_next_fn, next_type}, {iter_obj, iter_type} | rest],
         acc
       )
       when next_type in [:function, :unknown] and iter_type in [:object, :unknown] do
    call =
      Builder.remote_call(RuntimeABI, :iterator_close_for_throw, [Builder.ctx_var(), iter_obj])

    active_iterator_close_calls(rest, [call | acc])
  end

  defp active_iterator_close_calls([_entry | rest], acc),
    do: active_iterator_close_calls(rest, acc)

  defp active_iterator_close_calls([], acc), do: acc

  # ── Private helpers ──

  defp initial_slot_inits(0, _arg_count, _locals), do: %{}

  defp initial_slot_inits(slot_count, arg_count, locals) do
    Map.new(0..(slot_count - 1), fn idx ->
      initialized =
        cond do
          idx < arg_count -> true
          match?(%{is_lexical: true}, Enum.at(locals, idx)) -> false
          true -> true
        end

      {idx, initialized}
    end)
  end

  defp update_slot!(state, idx, expr, type) do
    {:ok, state} = update_slot(state, idx, expr, false, type)
    state
  end

  defp class_binding_slot(%{locals: locals, atoms: atoms}, atom_idx) do
    class_name = Atoms.resolve(atom_idx, atoms)

    locals
    |> Enum.with_index()
    |> Enum.filter(fn {%{name: name, scope_level: scope_level, is_lexical: is_lexical}, _idx} ->
      is_lexical and scope_level > 1 and Atoms.resolve(name, atoms) == class_name
    end)
    |> Enum.max_by(fn {%{scope_level: scope_level}, _idx} -> scope_level end, fn -> nil end)
    |> case do
      nil -> nil
      {_local, idx} -> idx
    end
  end

  defp invoke_call_expr(%{return_type: return_type} = state, _fun, :self_fun, args, _arg_types) do
    Effects.effectful_push(
      state,
      Builder.local_call(:run_ctx, [ctx_expr(state) | normalize_self_call_args(state, args)]),
      return_type
    )
  end

  defp invoke_call_expr(state, fun, fun_type, args, _arg_types) do
    {result, state} =
      Emit.bind(state, Builder.temp_name(state.temp), invoke_runtime_expr(state, fun, args))

    state =
      update_ctx(
        state,
        Builder.remote_call(QuickBEAM.VM.GlobalEnvironment, :refresh, [ctx_expr(state)])
      )

    {:ok, Emit.push(state, result, function_return_type(fun_type, state.return_type))}
  end

  defp tail_call_expr(state, _fun, :self_fun, args, _arg_types),
    do:
      Enum.reverse([
        Builder.local_call(:run_ctx, [ctx_expr(state) | normalize_self_call_args(state, args)])
        | state.body
      ])

  defp tail_call_expr(state, fun, _fun_type, args, _arg_types),
    do: Enum.reverse([invoke_runtime_expr(state, fun, args) | state.body])

  defp invoke_runtime_expr(state, fun, args) do
    case var_ref_fun_call(fun, length(args)) do
      {:ok, helper, idx, argc} when argc in 0..3 ->
        Builder.local_call(helper, [ctx_expr(state), idx | args])

      {:ok, helper, idx, _argc} ->
        Builder.local_call(helper, [ctx_expr(state), idx, Builder.list_expr(args)])

      :error ->
        Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_runtime, [
          ctx_expr(state),
          fun,
          Builder.list_expr(args)
        ])
    end
  end

  defp var_ref_fun_call(
         {:call, _, {:remote, _, {:atom, _, Bindings}, {:atom, _, fun}}, [_ctx, idx]},
         argc
       )
       when fun in [:get_var_ref, :get_var_ref_check] do
    {:ok, invoke_var_ref_helper(fun, argc), idx, argc}
  end

  defp var_ref_fun_call(_expr, _argc), do: :error

  defp invoke_var_ref_helper(:get_var_ref, argc),
    do: invoke_var_ref_helper_name(:invoke_var_ref, argc)

  defp invoke_var_ref_helper(:get_var_ref_check, argc),
    do: invoke_var_ref_helper_name(:invoke_var_ref_check, argc)

  defp invoke_var_ref_helper_name(prefix, argc) when argc in 0..3,
    do: String.to_atom("op_#{prefix}#{argc}")

  defp invoke_var_ref_helper_name(prefix, _argc), do: String.to_atom("op_#{prefix}")

  defp function_return_type(:self_fun, return_type), do: return_type
  defp function_return_type({:function, type}, _return_type), do: type
  defp function_return_type(_fun_type, _return_type), do: :unknown

  defp normalize_self_call_args(%{arg_count: arg_count}, args) do
    args
    |> Enum.take(arg_count)
    |> then(fn args ->
      args ++ List.duplicate(Builder.atom(:undefined), arg_count - length(args))
    end)
  end
end
