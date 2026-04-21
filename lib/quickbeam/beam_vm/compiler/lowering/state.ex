defmodule QuickBEAM.BeamVM.Compiler.Lowering.State do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.RuntimeHelpers
  alias QuickBEAM.BeamVM.Interpreter.Values

  @line 1

  def new(slot_count, stack_depth, opts \\ []) do
    slots =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, slot_var(idx)} end)

    capture_cells =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, capture_var(idx)} end)

    stack =
      if stack_depth == 0,
        do: [],
        else: Enum.map(0..(stack_depth - 1), &stack_var/1)

    %{
      body: [],
      slots: slots,
      slot_types:
        Keyword.get(opts, :slot_types, Map.new(slots, fn {idx, _expr} -> {idx, :unknown} end)),
      capture_cells: capture_cells,
      stack: stack,
      stack_types: Keyword.get(opts, :stack_types, List.duplicate(:unknown, stack_depth)),
      temp: 0,
      locals: Keyword.get(opts, :locals, []),
      atoms: Keyword.get(opts, :atoms),
      arg_count: Keyword.get(opts, :arg_count, 0),
      return_type: Keyword.get(opts, :return_type, :unknown)
    }
  end

  def push(state, expr), do: push(state, expr, infer_expr_type(expr))

  def push(state, expr, type),
    do: %{state | stack: [expr | state.stack], stack_types: [type | state.stack_types]}

  def pop_typed(%{stack: [expr | rest], stack_types: [type | type_rest]} = state),
    do: {:ok, expr, type, %{state | stack: rest, stack_types: type_rest}}

  def pop_typed(_state), do: {:error, :stack_underflow}

  def pop(%{stack: [expr | rest], stack_types: [_type | type_rest]} = state),
    do: {:ok, expr, %{state | stack: rest, stack_types: type_rest}}

  def pop(_state), do: {:error, :stack_underflow}

  def pop_n(state, 0), do: {:ok, [], state}

  def pop_n(state, count) when count > 0 do
    with {:ok, expr, state} <- pop(state),
         {:ok, rest, state} <- pop_n(state, count - 1) do
      {:ok, [expr | rest], state}
    end
  end

  def pop_n_typed(state, 0), do: {:ok, [], [], state}

  def pop_n_typed(state, count) when count > 0 do
    with {:ok, expr, type, state} <- pop_typed(state),
         {:ok, rest, rest_types, state} <- pop_n_typed(state, count - 1) do
      {:ok, [expr | rest], [type | rest_types], state}
    end
  end

  def put_slot(state, idx, expr), do: put_slot(state, idx, expr, infer_expr_type(expr))

  def put_slot(state, idx, expr, type) do
    %{
      state
      | slots: Map.put(state.slots, idx, expr),
        slot_types: Map.put(state.slot_types, idx, type)
    }
  end

  def slot_expr(state, idx), do: Map.get(state.slots, idx, atom(:undefined))
  def slot_type(state, idx), do: Map.get(state.slot_types, idx, :unknown)

  def put_capture_cell(state, idx, expr),
    do: %{state | capture_cells: Map.put(state.capture_cells, idx, expr)}

  def capture_cell_expr(state, idx), do: Map.get(state.capture_cells, idx, atom(:undefined))

  def bind_stack_entry(state, idx) do
    case Enum.fetch(state.stack, idx) do
      {:ok, expr} ->
        {bound, state} = bind(state, temp_name(state.temp), expr)
        {:ok, %{state | stack: List.replace_at(state.stack, idx, bound)}, bound}

      :error ->
        :error
    end
  end

  def assign_slot(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      expr = if wrapper, do: compiler_call(wrapper, [expr]), else: expr

      {slot_expr, state} =
        if keep? or not pure_expr?(expr) or slot_captured?(state, idx) do
          bind(state, slot_name(idx, state.temp), expr)
        else
          {expr, state}
        end

      state = put_slot(state, idx, slot_expr, type)
      state = sync_capture_cell(state, idx, slot_expr)
      state = if keep?, do: push(state, slot_expr, type), else: state
      {:ok, state}
    end
  end

  def update_slot(state, idx, expr),
    do: update_slot(state, idx, expr, false, infer_expr_type(expr))

  def update_slot(state, idx, expr, keep?),
    do: update_slot(state, idx, expr, keep?, infer_expr_type(expr))

  def update_slot(state, idx, expr, keep?, type) do
    {slot_expr, state} =
      if keep? or not pure_expr?(expr) or slot_captured?(state, idx) do
        bind(state, slot_name(idx, state.temp), expr)
      else
        {expr, state}
      end

    state = put_slot(state, idx, slot_expr, type)
    state = sync_capture_cell(state, idx, slot_expr)
    state = if keep?, do: push(state, slot_expr, type), else: state
    {:ok, state}
  end

  def ensure_capture_cell(state, idx) do
    {bound, state} =
      bind(
        state,
        capture_name(idx, state.temp),
        compiler_call(:ensure_capture_cell, [capture_cell_expr(state, idx), slot_expr(state, idx)])
      )

    {:ok, put_capture_cell(state, idx, bound), bound}
  end

  def close_capture_cell(state, idx) do
    {bound, state} =
      bind(
        state,
        capture_name(idx, state.temp),
        compiler_call(:close_capture_cell, [capture_cell_expr(state, idx), slot_expr(state, idx)])
      )

    {:ok, put_capture_cell(state, idx, bound)}
  end

  def duplicate_top(state) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      {bound, state} = bind(state, temp_name(state.temp), expr)

      {:ok,
       %{
         state
         | stack: [bound, bound | state.stack],
           stack_types: [type, type | state.stack_types]
       }}
    end
  end

  def duplicate_top_two(state) do
    with {:ok, first, first_type, state} <- pop_typed(state),
         {:ok, second, second_type, state} <- pop_typed(state) do
      {second_bound, state} = bind(state, temp_name(state.temp), second)
      {first_bound, state} = bind(state, temp_name(state.temp), first)

      {:ok,
       %{
         state
         | stack: [first_bound, second_bound, first_bound, second_bound | state.stack],
           stack_types: [first_type, second_type, first_type, second_type | state.stack_types]
       }}
    end
  end

  def drop_top(%{stack: [_ | rest], stack_types: [_ | type_rest]} = state),
    do: {:ok, %{state | stack: rest, stack_types: type_rest}}

  def drop_top(_state), do: {:error, :stack_underflow}

  def swap_top(%{stack: [a, b | rest], stack_types: [ta, tb | type_rest]} = state),
    do: {:ok, %{state | stack: [b, a | rest], stack_types: [tb, ta | type_rest]}}

  def swap_top(_state), do: {:error, :stack_underflow}

  def nip_catch(
        %{stack: [val, _catch_offset | rest], stack_types: [type, _ | type_rest]} = state
      ),
      do: {:ok, %{state | stack: [val | rest], stack_types: [type | type_rest]}}

  def nip_catch(_state), do: {:error, :stack_underflow}

  def post_update(state, fun) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      result_type = if type == :integer, do: :integer, else: :number
      {pair, state} = bind(state, temp_name(state.temp), compiler_call(fun, [expr]))

      {:ok,
       %{
         state
         | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack],
           stack_types: [result_type, result_type | state.stack_types]
       }}
    end
  end

  def add_to_slot(state, idx) do
    with {:ok, expr, expr_type, state} <- pop_typed(state) do
      {op_expr, result_type} =
        specialize_binary(:op_add, slot_expr(state, idx), slot_type(state, idx), expr, expr_type)

      update_slot(state, idx, op_expr, false, result_type)
    end
  end

  def inc_slot(state, idx),
    do:
      update_slot(
        state,
        idx,
        compiler_call(:inc, [slot_expr(state, idx)]),
        false,
        if(slot_type(state, idx) == :integer, do: :integer, else: :number)
      )

  def dec_slot(state, idx),
    do:
      update_slot(
        state,
        idx,
        compiler_call(:dec, [slot_expr(state, idx)]),
        false,
        if(slot_type(state, idx) == :integer, do: :integer, else: :number)
      )

  def unary_call(state, mod, fun, extra_args \\ []) do
    with {:ok, expr, _type, state} <- pop_typed(state) do
      {:ok, push(state, remote_call(mod, fun, [expr | extra_args]))}
    end
  end

  def effectful_push(state, expr), do: effectful_push(state, expr, infer_expr_type(expr))

  def effectful_push(state, expr, type) do
    {bound, state} = bind(state, temp_name(state.temp), expr)
    {:ok, push(state, bound, type)}
  end

  def unary_local_call(state, fun) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      {result_expr, result_type} = specialize_unary(fun, expr, type)
      {:ok, push(state, result_expr, result_type)}
    end
  end

  def binary_call(state, mod, fun) do
    with {:ok, right, _right_type, state} <- pop_typed(state),
         {:ok, left, _left_type, state} <- pop_typed(state) do
      {:ok, push(state, remote_call(mod, fun, [left, right]))}
    end
  end

  def binary_local_call(state, fun) do
    with {:ok, right, right_type, state} <- pop_typed(state),
         {:ok, left, left_type, state} <- pop_typed(state) do
      {result_expr, result_type} = specialize_binary(fun, left, left_type, right, right_type)
      {:ok, push(state, result_expr, result_type)}
    end
  end

  def get_field2(state, key_expr) do
    with {:ok, obj, _type, state} <- pop_typed(state) do
      field = remote_call(QuickBEAM.BeamVM.Runtime.Property, :get, [obj, key_expr])

      {:ok,
       %{
         state
         | stack: [field, obj | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  def get_array_el2(state) do
    with {:ok, idx, _idx_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      {pair, state} =
        bind(state, temp_name(state.temp), compiler_call(:get_array_el2, [obj, idx]))

      {:ok,
       %{
         state
         | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack],
           stack_types: [:unknown, :object | state.stack_types]
       }}
    end
  end

  def set_name_atom(state, atom_name) do
    with {:ok, fun, fun_type, state} <- pop_typed(state) do
      {:ok, push(state, compiler_call(:set_function_name, [fun, literal(atom_name)]), fun_type)}
    end
  end

  def set_name_computed(state) do
    with {:ok, fun, fun_type, state} <- pop_typed(state),
         {:ok, name, name_type, state} <- pop_typed(state) do
      named = compiler_call(:set_function_name_computed, [fun, name])

      {:ok,
       %{
         state
         | stack: [named, name | state.stack],
           stack_types: [fun_type, name_type | state.stack_types]
       }}
    end
  end

  def set_home_object(state) do
    with {:ok, state, method} <- bind_stack_entry(state, 0),
         {:ok, state, target} <- bind_stack_entry(state, 1) do
      {:ok, %{state | body: state.body ++ [compiler_call(:set_home_object, [method, target])]}}
    else
      :error -> {:error, :set_home_object_state_missing}
    end
  end

  def add_brand(state) do
    with {:ok, obj, state} <- pop(state),
         {:ok, brand, state} <- pop(state) do
      {:ok, %{state | body: state.body ++ [compiler_call(:add_brand, [obj, brand])]}}
    end
  end

  def put_field_call(state, key_expr) do
    with {:ok, val, _val_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      {:ok,
       %{
         state
         | body:
             state.body ++
               [remote_call(QuickBEAM.BeamVM.Interpreter.Objects, :put, [obj, key_expr, val])]
       }}
    end
  end

  def define_field_call(state, key_expr) do
    with {:ok, val, _val_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      {:ok, push(state, compiler_call(:define_field, [obj, key_expr, val]), :object)}
    end
  end

  def define_method_call(state, method_name, flags) do
    with {:ok, method, _method_type, state} <- pop_typed(state),
         {:ok, target, _target_type, state} <- pop_typed(state) do
      effectful_push(
        state,
        compiler_call(:define_method, [target, method, literal(method_name), literal(flags)]),
        :object
      )
    end
  end

  def define_method_computed_call(state, flags) do
    with {:ok, method, state} <- pop(state),
         {:ok, field_name, state} <- pop(state),
         {:ok, target, state} <- pop(state) do
      effectful_push(
        state,
        compiler_call(:define_method_computed, [target, method, field_name, literal(flags)])
      )
    end
  end

  def define_class_call(state, atom_idx) do
    with {:ok, ctor, state} <- pop(state),
         {:ok, parent_ctor, state} <- pop(state) do
      {pair, state} =
        bind(
          state,
          temp_name(state.temp),
          compiler_call(:define_class, [ctor, parent_ctor, literal(atom_idx)])
        )

      ctor = tuple_element(pair, 2)

      ctor_type = function_type_from_expr(ctor)

      state =
        case class_binding_slot(state, atom_idx) do
          nil -> state
          slot_idx -> update_slot!(state, slot_idx, ctor, ctor_type)
        end

      {:ok,
       %{
         state
         | stack: [tuple_element(pair, 1), ctor | state.stack],
           stack_types: [:object, ctor_type | state.stack_types]
       }}
    end
  end

  defp update_slot!(state, idx, expr, type) do
    {:ok, state} = update_slot(state, idx, expr, false, type)
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
    do: QuickBEAM.BeamVM.PredefinedAtoms.lookup(idx)

  defp resolve_local_name(idx, atoms)
       when is_integer(idx) and is_tuple(atoms) and idx < tuple_size(atoms),
       do: elem(atoms, idx)

  defp resolve_local_name(_name, _atoms), do: nil

  defp resolve_atom_name(atom_idx, atoms), do: resolve_local_name(atom_idx, atoms)

  def put_array_el_call(state) do
    with {:ok, val, _val_type, state} <- pop_typed(state),
         {:ok, idx, _idx_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      {:ok, %{state | body: state.body ++ [compiler_call(:put_array_el, [obj, idx, val])]}}
    end
  end

  def define_array_el_call(state) do
    with {:ok, val, _val_type, state} <- pop_typed(state),
         {:ok, idx, idx_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      {pair, state} =
        bind(state, temp_name(state.temp), compiler_call(:define_array_el, [obj, idx, val]))

      {:ok,
       %{
         state
         | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack],
           stack_types: [idx_type, :object | state.stack_types]
       }}
    end
  end

  def invoke_call(state, argc) do
    with {:ok, args, arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, fun_type, state} <- pop_typed(state) do
      invoke_call_expr(state, fun, fun_type, Enum.reverse(args), Enum.reverse(arg_types))
    end
  end

  def invoke_constructor_call(state, argc) do
    with {:ok, args, _arg_types, state} <- pop_n_typed(state, argc),
         {:ok, new_target, _new_target_type, state} <- pop_typed(state),
         {:ok, ctor, _ctor_type, state} <- pop_typed(state) do
      effectful_push(
        state,
        compiler_call(:construct_runtime, [ctor, new_target, list_expr(Enum.reverse(args))]),
        :object
      )
    end
  end

  def invoke_tail_call(state, argc) do
    with {:ok, args, arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, fun_type, %{stack: [], stack_types: []} = state} <- pop_typed(state) do
      {:done, tail_call_expr(state, fun, fun_type, Enum.reverse(args), Enum.reverse(arg_types))}
    else
      {:ok, _fun, _fun_type, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  def invoke_method_call(state, argc) do
    with {:ok, args, _arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, fun_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      effectful_push(
        state,
        compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))]),
        function_return_type(fun_type, state.return_type)
      )
    end
  end

  def array_from_call(state, argc) do
    with {:ok, elems, _types, state} <- pop_n_typed(state, argc) do
      {:ok, push(state, compiler_call(:array_from, [list_expr(Enum.reverse(elems))]), :object)}
    end
  end

  def in_call(state) do
    with {:ok, obj, _obj_type, state} <- pop_typed(state),
         {:ok, key, _key_type, state} <- pop_typed(state) do
      {:ok,
       push(
         state,
         remote_call(QuickBEAM.BeamVM.Interpreter.Objects, :has_property, [obj, key]),
         :boolean
       )}
    end
  end

  def append_call(state) do
    with {:ok, obj, _obj_type, state} <- pop_typed(state),
         {:ok, idx, _idx_type, state} <- pop_typed(state),
         {:ok, arr, _arr_type, state} <- pop_typed(state) do
      {pair, state} =
        bind(state, temp_name(state.temp), compiler_call(:append_spread, [arr, idx, obj]))

      {:ok,
       %{
         state
         | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack],
           stack_types: [:number, :object | state.stack_types]
       }}
    end
  end

  def copy_data_properties_call(state, mask) do
    target_idx = Bitwise.band(mask, 3)
    source_idx = Bitwise.band(Bitwise.bsr(mask, 2), 7)

    with {:ok, state, target} <- bind_stack_entry(state, target_idx),
         {:ok, state, source} <- bind_stack_entry(state, source_idx) do
      {:ok,
       %{state | body: state.body ++ [compiler_call(:copy_data_properties, [target, source])]}}
    else
      :error -> {:error, {:copy_data_properties_missing, mask, target_idx, source_idx}}
    end
  end

  def delete_call(state) do
    with {:ok, key, _key_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      effectful_push(state, compiler_call(:delete_property, [obj, key]), :boolean)
    end
  end

  def invoke_tail_method_call(state, argc) do
    with {:ok, args, _arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, _fun_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, %{stack: [], stack_types: []} = state} <- pop_typed(state) do
      {:done,
       state.body ++
         [compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))])]}
    else
      {:ok, _obj, _obj_type, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  def goto(state, target, stack_depths) do
    with {:ok, call} <- block_jump_call(state, target, stack_depths) do
      {:done, state.body ++ [call]}
    end
  end

  def branch(%{stack: stack}, idx, next_entry, target, sense, _stack_depths) when stack == [] do
    {:error, {:missing_branch_condition, idx, target, sense, next_entry}}
  end

  def branch(state, _idx, next_entry, target, sense, _stack_depths) when is_nil(next_entry) do
    {:error, {:missing_fallthrough_block, target, sense, state.body}}
  end

  def branch(state, _idx, next_entry, target, sense, stack_depths) do
    with {:ok, cond_expr, cond_type, state} <- pop_typed(state),
         {:ok, target_call} <- block_jump_call(state, target, stack_depths),
         {:ok, next_call} <- block_jump_call(state, next_entry, stack_depths) do
      truthy = branch_condition(cond_expr, cond_type)
      false_body = [target_call]
      true_body = [next_call]

      body =
        if sense do
          state.body ++ [case_expr(truthy, true_body, false_body)]
        else
          state.body ++ [case_expr(truthy, false_body, true_body)]
        end

      {:done, body}
    end
  end

  def return_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:done, state.body ++ [expr]}
    end
  end

  def throw_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:done, state.body ++ [throw_js(expr)]}
    end
  end

  def bind(state, name, expr) do
    var = var(name)
    {var, %{state | body: state.body ++ [match(var, expr)], temp: state.temp + 1}}
  end

  def block_jump_call(state, target, stack_depths) do
    block_jump_call_values(
      target,
      stack_depths,
      current_slots(state),
      current_stack(state),
      current_capture_cells(state)
    )
  end

  def block_jump_call_values(target, stack_depths, slots, stack, capture_cells) do
    expected_depth = Map.get(stack_depths, target)
    actual_depth = length(stack)

    cond do
      is_nil(expected_depth) ->
        {:error, {:unknown_block_target, target}}

      expected_depth != actual_depth ->
        {:error, {:stack_depth_mismatch, target, expected_depth, actual_depth}}

      true ->
        {:ok, local_call(block_name(target), slots ++ stack ++ capture_cells)}
    end
  end

  def current_slots(state), do: ordered_values(state.slots)
  def current_stack(state), do: state.stack
  def current_capture_cells(state), do: ordered_values(state.capture_cells)

  def block_name(idx), do: String.to_atom("block_#{idx}")
  def slot_name(idx, n), do: "Slot#{idx}_#{n}"
  def capture_name(idx, n), do: "Capture#{idx}_#{n}"
  def temp_name(n), do: "Tmp#{n}"
  def slot_var(idx), do: var("Slot#{idx}")
  def stack_var(idx), do: var("Stack#{idx}")
  def capture_var(idx), do: var("Capture#{idx}")
  def slot_vars(0), do: []
  def slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  def stack_vars(0), do: []
  def stack_vars(count), do: Enum.map(0..(count - 1), &stack_var/1)
  def capture_vars(0), do: []
  def capture_vars(count), do: Enum.map(0..(count - 1), &capture_var/1)

  def var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  def var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  def var(name) when is_atom(name), do: {:var, @line, name}

  def integer(value), do: {:integer, @line, value}
  def atom(value), do: {:atom, @line, value}
  def literal(value), do: :erl_parse.abstract(value)
  def match(left, right), do: {:match, @line, left, right}

  def tuple_element(tuple, index) do
    {:call, @line, {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :element}},
     [integer(index), tuple]}
  end

  def tuple_expr(values), do: {:tuple, @line, values}

  def map_expr(entries) do
    {:map, @line, Enum.map(entries, fn {key, value} -> {:map_field_assoc, @line, key, value} end)}
  end

  def list_expr([]), do: {nil, @line}
  def list_expr([head | tail]), do: {:cons, @line, head, list_expr(tail)}

  def remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  def local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}
  def compiler_call(fun, args), do: remote_call(RuntimeHelpers, fun, args)

  def throw_js(expr), do: remote_call(:erlang, :throw, [{:tuple, @line, [atom(:js_throw), expr]}])

  def try_catch_expr(try_body, err_var, catch_body) do
    {:try, @line, try_body, [], [catch_clause(err_var, catch_body)], []}
  end

  def undefined_or_null_expr(expr) do
    {:case, @line, expr,
     [
       {:clause, @line, [atom(:undefined)], [], [atom(true)]},
       {:clause, @line, [atom(nil)], [], [atom(true)]},
       {:clause, @line, [var(:_)], [], [atom(false)]}
     ]}
  end

  def branch_condition(expr, :boolean), do: expr
  def branch_condition(expr, _type), do: remote_call(Values, :truthy?, [expr])
  def branch_case(expr, false_body, true_body), do: case_expr(expr, false_body, true_body)

  def atom_name(state, atom_idx), do: resolve_atom_name(atom_idx, state.atoms)

  def infer_expr_type({:integer, _, _}), do: :integer
  def infer_expr_type({:float, _, _}), do: :number
  def infer_expr_type({:char, _, _}), do: :integer
  def infer_expr_type({:string, _, _}), do: :string
  def infer_expr_type({:bin, _, _}), do: :string
  def infer_expr_type({:atom, _, true}), do: :boolean
  def infer_expr_type({:atom, _, false}), do: :boolean
  def infer_expr_type({:atom, _, :undefined}), do: :undefined
  def infer_expr_type({:atom, _, nil}), do: :null
  def infer_expr_type(_), do: :unknown

  def pure_expr?({:integer, _, _}), do: true
  def pure_expr?({:float, _, _}), do: true
  def pure_expr?({:char, _, _}), do: true
  def pure_expr?({:string, _, _}), do: true
  def pure_expr?({:atom, _, _}), do: true
  def pure_expr?({nil, _}), do: true
  def pure_expr?({:var, _, _}), do: true
  def pure_expr?({:tuple, _, values}), do: Enum.all?(values, &pure_expr?/1)
  def pure_expr?({:cons, _, head, tail}), do: pure_expr?(head) and pure_expr?(tail)
  def pure_expr?({:map, _, fields}), do: Enum.all?(fields, &pure_map_field?/1)
  def pure_expr?(_), do: false

  defp pure_map_field?({:map_field_assoc, _, key, value}),
    do: pure_expr?(key) and pure_expr?(value)

  defp pure_map_field?(_), do: false

  defp slot_captured?(%{locals: locals}, idx) when is_list(locals) do
    case Enum.at(locals, idx) do
      %{is_captured: true} -> true
      _ -> false
    end
  end

  defp slot_captured?(_state, _idx), do: false

  defp invoke_call_expr(%{return_type: return_type} = state, _fun, :self_fun, args, _arg_types) do
    effectful_push(state, local_call(:run, normalize_self_call_args(state, args)), return_type)
  end

  defp invoke_call_expr(state, fun, fun_type, args, _arg_types) do
    effectful_push(
      state,
      compiler_call(:invoke_runtime, [fun, list_expr(args)]),
      function_return_type(fun_type, state.return_type)
    )
  end

  defp tail_call_expr(state, _fun, :self_fun, args, _arg_types),
    do: state.body ++ [local_call(:run, normalize_self_call_args(state, args))]

  defp tail_call_expr(state, fun, _fun_type, args, _arg_types),
    do: state.body ++ [compiler_call(:invoke_runtime, [fun, list_expr(args)])]

  defp specialize_unary(:op_neg, expr, :integer), do: {{:op, @line, :-, expr}, :integer}
  defp specialize_unary(:op_neg, expr, :number), do: {{:op, @line, :-, expr}, :number}
  defp specialize_unary(:op_plus, expr, type) when type in [:integer, :number], do: {expr, type}
  defp specialize_unary(fun, expr, _type), do: {local_call(fun, [expr]), :unknown}

  defp specialize_binary(:op_add, left, :integer, right, :integer),
    do: {{:op, @line, :+, left, right}, :integer}

  defp specialize_binary(:op_add, left, left_type, right, right_type)
       when left_type in [:integer, :number] and right_type in [:integer, :number],
       do:
         {{:op, @line, :+, left, right},
          if(left_type == :integer and right_type == :integer, do: :integer, else: :number)}

  defp specialize_binary(:op_add, left, :string, right, :string),
    do: {binary_concat(left, right), :string}

  defp specialize_binary(fun, left, left_type, right, right_type)
       when fun in [:op_sub, :op_mul] and left_type == :integer and right_type == :integer,
       do: {{:op, @line, binary_operator(fun), left, right}, :integer}

  defp specialize_binary(fun, left, left_type, right, right_type)
       when fun in [:op_sub, :op_mul, :op_div, :op_lt, :op_lte, :op_gt, :op_gte] and
              left_type in [:integer, :number] and right_type in [:integer, :number] do
    {type, op} =
      case fun do
        :op_sub -> {:number, :-}
        :op_mul -> {:number, :*}
        :op_div -> {:number, :/}
        :op_lt -> {:boolean, :<}
        :op_lte -> {:boolean, :"=<"}
        :op_gt -> {:boolean, :>}
        :op_gte -> {:boolean, :>=}
      end

    {{:op, @line, op, left, right}, type}
  end

  defp specialize_binary(fun, left, _left_type, right, _right_type),
    do: {local_call(fun, [left, right]), :unknown}

  defp binary_operator(:op_sub), do: :-
  defp binary_operator(:op_mul), do: :*

  defp normalize_self_call_args(%{arg_count: arg_count}, args) do
    args
    |> Enum.take(arg_count)
    |> then(fn args -> args ++ List.duplicate(atom(:undefined), arg_count - length(args)) end)
  end

  defp function_return_type(:self_fun, return_type), do: return_type
  defp function_return_type({:function, type}, _return_type), do: type
  defp function_return_type(_fun_type, _return_type), do: :unknown

  defp function_type_from_expr(expr), do: infer_expr_type(expr)

  defp binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end

  defp ordered_values(values) do
    values
    |> Enum.sort_by(fn {idx, _expr} -> idx end)
    |> Enum.map(fn {_idx, expr} -> expr end)
  end

  defp sync_capture_cell(state, idx, expr) do
    if slot_captured?(state, idx) do
      %{
        state
        | body:
            state.body ++
              [compiler_call(:sync_capture_cell, [capture_cell_expr(state, idx), expr])]
      }
    else
      state
    end
  end

  defp case_expr(expr, false_body, true_body) do
    {:case, @line, expr,
     [
       {:clause, @line, [atom(false)], [], false_body},
       {:clause, @line, [atom(true)], [], true_body}
     ]}
  end

  defp catch_clause(err_var, catch_body) do
    pattern =
      {:tuple, @line, [atom(:throw), {:tuple, @line, [atom(:js_throw), err_var]}, var(:_)]}

    {:clause, @line, [pattern], [], catch_body}
  end
end
