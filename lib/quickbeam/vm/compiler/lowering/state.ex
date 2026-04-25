defmodule QuickBEAM.VM.Compiler.Lowering.State do
  @moduledoc "Lowering accumulator: tracks the operand stack, slot bindings, and emitted body forms during a block compilation."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Types}
  alias QuickBEAM.VM.Compiler.Lowering.State.{Calls, Slots, Stack}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  @line 1

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  def new(slot_count, stack_depth, opts \\ []) do
    slots =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, Builder.slot_var(idx)} end)

    capture_cells =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, Builder.capture_var(idx)} end)

    stack =
      if stack_depth == 0,
        do: [],
        else: Enum.map(0..(stack_depth - 1), &Builder.stack_var/1)

    arg_count = Keyword.get(opts, :arg_count, 0)
    locals = Keyword.get(opts, :locals, [])

    %{
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
      return_type: Keyword.get(opts, :return_type, :unknown)
    }
  end

  # ---------------------------------------------------------------------------
  # Core state accessors and emitters
  # ---------------------------------------------------------------------------

  def emit(state, expr), do: %{state | body: [expr | state.body]}
  def emit_all(state, exprs), do: %{state | body: Enum.reverse(exprs, state.body)}

  def ctx_expr(%{ctx: ctx}), do: ctx
  def closure_vars_expr(%{closure_vars: cvs}), do: cvs

  def inline_get_var_ref(state, idx) do
    cvs = closure_vars_expr(state)

    case Enum.at(cvs, idx) do
      %{closure_type: type, var_idx: var_idx} ->
        key = Builder.literal({type, var_idx})
        {bound, state} = bind(state, Builder.temp_name(state.temp), compiler_call(state, :get_capture, [key]))
        {bound, state}

      nil ->
        {Builder.atom(:undefined), state}
    end
  end

  def compiler_call(state, fun, args),
    do: Builder.remote_call(RuntimeHelpers, fun, [ctx_expr(state) | args])

  def bind(state, name, expr) do
    var = Builder.var(name)
    {var, %{state | body: [Builder.match(var, expr) | state.body], temp: state.temp + 1}}
  end

  def update_ctx(state, expr) do
    {ctx, state} = bind(state, "Ctx#{state.temp}", expr)
    %{state | ctx: ctx}
  end

  def current_stack(state), do: state.stack

  def block_jump_call(state, target, stack_depths) do
    Calls.block_jump_call_values(
      target,
      stack_depths,
      ctx_expr(state),
      Slots.current_slots(state),
      state.stack,
      Slots.current_capture_cells(state)
    )
  end

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
    with {:ok, cond_expr, cond_type, state} <- Stack.pop_typed(state),
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

  def regexp_literal(state) do
    with {:ok, pattern, _pattern_type, state} <- Stack.pop_typed(state),
         {:ok, flags, _flags_type, state} <- Stack.pop_typed(state) do
      {:ok, Stack.push(state, Builder.tuple_expr([Builder.atom(:regexp), pattern, flags]), :unknown)}
    end
  end

  def add_to_slot(state, idx) do
    with {:ok, expr, expr_type, state} <- Stack.pop_typed(state) do
      {op_expr, result_type} =
        Calls.specialize_binary(
          :op_add,
          Slots.slot_expr(state, idx),
          Slots.slot_type(state, idx),
          expr,
          expr_type
        )

      Slots.update_slot(state, idx, op_expr, false, result_type)
    end
  end

  def inc_slot(state, idx),
    do:
      Slots.update_slot(
        state,
        idx,
        compiler_call(state, :inc, [Slots.slot_expr(state, idx)]),
        false,
        if(Slots.slot_type(state, idx) == :integer, do: :integer, else: :number)
      )

  def dec_slot(state, idx),
    do:
      Slots.update_slot(
        state,
        idx,
        compiler_call(state, :dec, [Slots.slot_expr(state, idx)]),
        false,
        if(Slots.slot_type(state, idx) == :integer, do: :integer, else: :number)
      )

  def get_field_call(state, key_expr) do
    with {:ok, obj, type, state} <- Stack.pop_typed(state) do
      key_str = extract_literal_string(key_expr)

      case {type, key_str} do
        {{:shaped_object, offsets}, key} when is_binary(key) and is_map_key(offsets, key) ->
          offset = Map.fetch!(offsets, key)

          id_var = Builder.var(Builder.temp_name(state.temp))
          vals_var = Builder.var(Builder.temp_name(state.temp + 1))
          state = %{state | temp: state.temp + 2}

          access_expr =
            {:case, @line, obj,
             [
               {:clause, @line, [{:tuple, @line, [{:atom, @line, :obj}, id_var]}], [],
                [
                  {:case, @line,
                   {:call, @line, {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :get}},
                    [id_var]},
                   [
                     {:clause, @line,
                      [
                        {:tuple, @line,
                         [
                           {:atom, @line, :shape},
                           {:var, @line, :_},
                           {:var, @line, :_},
                           vals_var,
                           {:var, @line, :_}
                         ]}
                      ], [],
                      [
                        {:call, @line,
                         {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :element}},
                         [{:integer, @line, offset + 1}, vals_var]}
                      ]},
                     {:clause, @line, [{:var, @line, :_}], [],
                      [Builder.local_call(:op_get_field, [obj, key_expr])]}
                   ]}
                ]},
               {:clause, @line, [{:var, @line, :_}], [],
                [Builder.local_call(:op_get_field, [obj, key_expr])]}
             ]}

          {:ok, Stack.push(state, access_expr)}

        _ ->
          {:ok, Stack.push(state, Builder.local_call(:op_get_field, [obj, key_expr]))}
      end
    end
  end

  def get_field2(state, key_expr) do
    with {:ok, obj, _type, state} <- Stack.pop_typed(state) do
      field = Builder.local_call(:op_get_field, [obj, key_expr])

      {:ok,
       %{
         state
         | stack: [field, obj | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  def get_array_el2(state) do
    with {:ok, idx, _idx_type, state} <- Stack.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Stack.pop_typed(state) do
      {pair, state} =
        bind(
          state,
          Builder.temp_name(state.temp),
          compiler_call(state, :get_array_el2, [obj, idx])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  def set_name_atom(state, atom_name) do
    with {:ok, fun, fun_type, state} <- Stack.pop_typed(state) do
      {:ok,
       Stack.push(
         state,
         compiler_call(state, :set_function_name, [fun, Builder.literal(atom_name)]),
         fun_type
       )}
    end
  end

  def set_name_computed(state) do
    with {:ok, fun, fun_type, state} <- Stack.pop_typed(state),
         {:ok, name, name_type, state} <- Stack.pop_typed(state) do
      named = compiler_call(state, :set_function_name_computed, [fun, name])

      {:ok,
       %{
         state
         | stack: [named, name | state.stack],
           stack_types: [fun_type, name_type | state.stack_types]
       }}
    end
  end

  def set_home_object(state) do
    with {:ok, state, method} <- Stack.bind_stack_entry(state, 0),
         {:ok, state, target} <- Stack.bind_stack_entry(state, 1) do
      {:ok, emit(state, compiler_call(state, :set_home_object, [method, target]))}
    else
      :error -> {:error, :set_home_object_state_missing}
    end
  end

  def add_brand(state) do
    with {:ok, obj, state} <- Stack.pop(state),
         {:ok, brand, state} <- Stack.pop(state) do
      {:ok, emit(state, compiler_call(state, :add_brand, [obj, brand]))}
    end
  end

  def put_field_call(state, key_expr) do
    with {:ok, val, _val_type, state} <- Stack.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Stack.pop_typed(state) do
      {:ok, emit(state, Builder.remote_call(QuickBEAM.VM.ObjectModel.Put, :put, [obj, key_expr, val]))}
    end
  end

  def define_field_name_call(state, key_expr) do
    with {:ok, val, _val_type, state} <- Stack.pop_typed(state),
         {:ok, obj, obj_type, state} <- Stack.pop_typed(state) do
      key_str = extract_literal_string(key_expr)

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
       |> emit(Builder.remote_call(QuickBEAM.VM.ObjectModel.Put, :put_field, [obj, key_expr, val]))
       |> Stack.push(obj, new_type)}
    end
  end

  def define_method_call(state, method_name, flags) do
    with {:ok, method, _method_type, state} <- Stack.pop_typed(state),
         {:ok, target, _target_type, state} <- Stack.pop_typed(state) do
      Calls.effectful_push(
        state,
        compiler_call(state, :define_method, [
          target,
          method,
          Builder.literal(method_name),
          Builder.literal(flags)
        ]),
        :object
      )
    end
  end

  def define_method_computed_call(state, flags) do
    with {:ok, method, state} <- Stack.pop(state),
         {:ok, field_name, state} <- Stack.pop(state),
         {:ok, target, state} <- Stack.pop(state) do
      Calls.effectful_push(
        state,
        compiler_call(state, :define_method_computed, [
          target,
          method,
          field_name,
          Builder.literal(flags)
        ])
      )
    end
  end

  def define_class_call(state, atom_idx) do
    with {:ok, ctor, state} <- Stack.pop(state),
         {:ok, parent_ctor, state} <- Stack.pop(state) do
      {pair, state} =
        bind(
          state,
          Builder.temp_name(state.temp),
          compiler_call(state, :define_class, [ctor, parent_ctor, Builder.literal(atom_idx)])
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

  def put_array_el_call(state) do
    with {:ok, val, _val_type, state} <- Stack.pop_typed(state),
         {:ok, idx, _idx_type, state} <- Stack.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Stack.pop_typed(state) do
      {:ok, emit(state, compiler_call(state, :put_array_el, [obj, idx, val]))}
    end
  end

  def define_array_el_call(state) do
    with {:ok, val, _val_type, state} <- Stack.pop_typed(state),
         {:ok, idx, idx_type, state} <- Stack.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Stack.pop_typed(state) do
      {pair, state} =
        bind(
          state,
          Builder.temp_name(state.temp),
          compiler_call(state, :define_array_el, [obj, idx, val])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [idx_type, :object | state.stack_types]
       }}
    end
  end

  def array_from_call(state, argc) do
    with {:ok, elems, _types, state} <- Stack.pop_n_typed(state, argc) do
      {:ok,
       Stack.push(
         state,
         compiler_call(state, :array_from, [Builder.list_expr(Enum.reverse(elems))]),
         :object
       )}
    end
  end

  def in_call(state) do
    with {:ok, obj, _obj_type, state} <- Stack.pop_typed(state),
         {:ok, key, _key_type, state} <- Stack.pop_typed(state) do
      {:ok,
       Stack.push(
         state,
         Builder.remote_call(QuickBEAM.VM.ObjectModel.Put, :has_property, [obj, key]),
         :boolean
       )}
    end
  end

  def append_call(state) do
    with {:ok, obj, _obj_type, state} <- Stack.pop_typed(state),
         {:ok, idx, _idx_type, state} <- Stack.pop_typed(state),
         {:ok, arr, _arr_type, state} <- Stack.pop_typed(state) do
      {pair, state} =
        bind(
          state,
          Builder.temp_name(state.temp),
          compiler_call(state, :append_spread, [arr, idx, obj])
        )

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [:number, :object | state.stack_types]
       }}
    end
  end

  def copy_data_properties_call(state, mask) do
    target_idx = Bitwise.band(mask, 3)
    source_idx = Bitwise.band(Bitwise.bsr(mask, 2), 7)

    with {:ok, state, target} <- Stack.bind_stack_entry(state, target_idx),
         {:ok, state, source} <- Stack.bind_stack_entry(state, source_idx) do
      {:ok, %{state | body: [compiler_call(state, :copy_data_properties, [target, source]) | state.body]}}
    else
      :error -> {:error, {:copy_data_properties_missing, mask, target_idx, source_idx}}
    end
  end

  def delete_call(state) do
    with {:ok, key, _key_type, state} <- Stack.pop_typed(state),
         {:ok, obj, _obj_type, state} <- Stack.pop_typed(state) do
      Calls.effectful_push(state, compiler_call(state, :delete_property, [obj, key]), :boolean)
    end
  end

  # ---------------------------------------------------------------------------
  # Delegations to Stack
  # ---------------------------------------------------------------------------

  defdelegate push(state, expr), to: Stack
  defdelegate push(state, expr, type), to: Stack
  defdelegate pop(state), to: Stack
  defdelegate pop_typed(state), to: Stack
  defdelegate pop_n(state, count), to: Stack
  defdelegate pop_n_typed(state, count), to: Stack
  defdelegate bind_stack_entry(state, idx), to: Stack
  defdelegate duplicate_top(state), to: Stack
  defdelegate duplicate_top_two(state), to: Stack
  defdelegate insert_top_two(state), to: Stack
  defdelegate insert_top_three(state), to: Stack
  defdelegate drop_top(state), to: Stack
  defdelegate swap_top(state), to: Stack
  defdelegate permute_top_three(state), to: Stack

  # ---------------------------------------------------------------------------
  # Delegations to Slots
  # ---------------------------------------------------------------------------

  defdelegate put_slot(state, idx, expr), to: Slots
  defdelegate put_slot(state, idx, expr, type), to: Slots
  defdelegate put_uninitialized_slot(state, idx, expr), to: Slots
  defdelegate put_uninitialized_slot(state, idx, expr, type), to: Slots
  defdelegate slot_expr(state, idx), to: Slots
  defdelegate slot_type(state, idx), to: Slots
  defdelegate slot_initialized?(state, idx), to: Slots
  defdelegate put_capture_cell(state, idx, expr), to: Slots
  defdelegate capture_cell_expr(state, idx), to: Slots
  defdelegate assign_slot(state, idx, keep?), to: Slots
  defdelegate assign_slot(state, idx, keep?, wrapper), to: Slots
  defdelegate update_slot(state, idx, expr), to: Slots
  defdelegate update_slot(state, idx, expr, keep?), to: Slots
  defdelegate update_slot(state, idx, expr, keep?, type), to: Slots
  defdelegate current_slots(state), to: Slots
  defdelegate current_capture_cells(state), to: Slots

  # ---------------------------------------------------------------------------
  # Delegations to Calls
  # ---------------------------------------------------------------------------

  defdelegate nip_catch(state), to: Calls
  defdelegate post_update(state, fun), to: Calls
  defdelegate effectful_push(state, expr), to: Calls
  defdelegate effectful_push(state, expr, type), to: Calls
  defdelegate unary_call(state, mod, fun), to: Calls
  defdelegate unary_call(state, mod, fun, extra_args), to: Calls
  defdelegate get_length_call(state), to: Calls
  defdelegate unary_local_call(state, fun), to: Calls
  defdelegate binary_call(state, mod, fun), to: Calls
  defdelegate binary_local_call(state, fun), to: Calls
  defdelegate invoke_call(state, argc), to: Calls
  defdelegate invoke_constructor_call(state, argc), to: Calls
  defdelegate invoke_tail_call(state, argc), to: Calls
  defdelegate invoke_method_call(state, argc), to: Calls
  defdelegate invoke_tail_method_call(state, argc), to: Calls
  defdelegate block_jump_call_values(target, stack_depths, ctx, slots, stack, capture_cells), to: Calls
  defdelegate return_top(state), to: Calls
  defdelegate throw_top(state), to: Calls

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_literal_string({:bin, _, [{:bin_element, _, {:string, _, chars}, _, _}]}),
    do: List.to_string(chars)

  defp extract_literal_string(_), do: nil

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
    {:ok, state} = Slots.update_slot(state, idx, expr, false, type)
    state
  end

  defp class_binding_slot(%{locals: locals, atoms: atoms}, atom_idx) do
    class_name = resolve_atom_name(atom_idx, atoms)

    locals
    |> Enum.with_index()
    |> Enum.filter(fn {%{name: name, scope_level: scope_level, is_lexical: is_lexical}, _idx} ->
      is_lexical and scope_level > 1 and resolve_local_name(name, atoms) == class_name
    end)
    |> Enum.max_by(fn {%{scope_level: scope_level}, _idx} -> scope_level end, fn -> nil end)
    |> case do
      nil -> nil
      {_local, idx} -> idx
    end
  end

  defp resolve_local_name(name, _atoms) when is_binary(name), do: name

  defp resolve_local_name({:predefined, idx}, _atoms),
    do: QuickBEAM.VM.PredefinedAtoms.lookup(idx)

  defp resolve_local_name(idx, atoms)
       when is_integer(idx) and is_tuple(atoms) and idx < tuple_size(atoms),
       do: elem(atoms, idx)

  defp resolve_local_name(_name, _atoms), do: nil

  defp resolve_atom_name(atom_idx, atoms), do: resolve_local_name(atom_idx, atoms)
end
