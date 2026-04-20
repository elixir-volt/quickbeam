defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.BeamVM.{Builtin, Bytecode, Decoder, Heap, Opcodes}
  alias QuickBEAM.BeamVM.Interpreter.{Scope, Values}
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Runtime.Property

  @line 1
  @tdz :__tdz__

  @type compiled_fun :: {module(), atom()}

  def invoke(%Bytecode.Function{closure_vars: []} = fun, args) do
    key = {fun.byte_code, fun.arg_count}

    if atoms = Process.get({:qb_fn_atoms, fun.byte_code}) do
      Heap.put_atoms(atoms)
    end

    case Heap.get_compiled(key) do
      {:compiled, {mod, name}} -> {:ok, apply(mod, name, args)}
      :unsupported -> :error
      nil -> compile_and_invoke(fun, args, key)
    end
  end

  def invoke(_, _), do: :error

  def compile(%Bytecode.Function{closure_vars: []} = fun) do
    module = module_name(fun)
    entry = entry_name()

    case :code.is_loaded(module) do
      {:file, _} ->
        {:ok, {module, entry}}

      false ->
        with {:ok, instructions} <- Decoder.decode(fun.byte_code, fun.arg_count),
             {:ok, {slot_count, block_forms}} <- lower(fun, instructions),
             {:ok, _module, binary} <-
               compile_forms(module, entry, fun.arg_count, slot_count, block_forms),
             {:module, ^module} <- :code.load_binary(module, ~c"quickbeam_compiler", binary) do
          {:ok, {module, entry}}
        else
          {:error, _} = error -> error
          other -> {:error, {:load_failed, other}}
        end
    end
  end

  def compile(_), do: {:error, :closure_not_supported}

  def ensure_initialized_local!(val) do
    if val == @tdz do
      throw(
        {:js_throw,
         Heap.make_error("Cannot access variable before initialization", "ReferenceError")}
      )
    end

    val
  end

  def strict_neq(a, b), do: not Values.strict_eq(a, b)

  def get_var(atom_idx) do
    globals = current_globals()
    name = atom_name(atom_idx)

    case Map.fetch(globals, name) do
      {:ok, val} -> val
      :error -> throw({:js_throw, Heap.make_error("#{name} is not defined", "ReferenceError")})
    end
  end

  def get_var_undef(atom_idx) do
    globals = current_globals()
    Map.get(globals, atom_name(atom_idx), :undefined)
  end

  def new_object do
    proto = Heap.get_object_prototype()
    init = if proto, do: %{proto() => proto}, else: %{}
    Heap.wrap(init)
  end

  def array_from(list), do: Heap.wrap(list)

  def get_field(obj, atom_idx), do: Property.get(obj, atom_name(atom_idx))

  def put_field(obj, atom_idx, val) do
    QuickBEAM.BeamVM.Interpreter.Objects.put(obj, atom_name(atom_idx), val)
    :ok
  end

  def define_field(obj, atom_idx, val) do
    QuickBEAM.BeamVM.Interpreter.Objects.put(obj, atom_name(atom_idx), val)
    obj
  end

  def put_array_el(obj, idx, val) do
    QuickBEAM.BeamVM.Interpreter.Objects.put_element(obj, idx, val)
    :ok
  end

  def is_undefined_or_null(val), do: val == :undefined or val == nil

  def invoke_runtime(fun, args) do
    case fun do
      %Bytecode.Function{} ->
        QuickBEAM.BeamVM.Interpreter.invoke(fun, args, Runtime.gas_budget())

      {:closure, _, %Bytecode.Function{}} ->
        QuickBEAM.BeamVM.Interpreter.invoke(fun, args, Runtime.gas_budget())

      {:bound, _, inner, _, _} ->
        invoke_runtime(inner, args)

      other ->
        Builtin.call(other, args, nil)
    end
  end

  def invoke_method_runtime(fun, this_obj, args) do
    case fun do
      %Bytecode.Function{} ->
        QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(
          fun,
          args,
          Runtime.gas_budget(),
          this_obj
        )

      {:closure, _, %Bytecode.Function{}} ->
        QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(
          fun,
          args,
          Runtime.gas_budget(),
          this_obj
        )

      {:bound, _, inner, _, _} ->
        invoke_method_runtime(inner, this_obj, args)

      other ->
        Builtin.call(other, args, this_obj)
    end
  end

  def get_length(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.size(arr)
          list when is_list(list) -> length(list)
          map when is_map(map) -> Map.get(map, "length", map_size(map))
          _ -> 0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      s when is_binary(s) ->
        Property.string_length(s)

      %Bytecode.Function{} = fun ->
        fun.defined_arg_count

      {:closure, _, %Bytecode.Function{} = fun} ->
        fun.defined_arg_count

      {:bound, len, _, _, _} ->
        len

      _ ->
        :undefined
    end
  end

  defp compile_and_invoke(fun, args, key) do
    case compile(fun) do
      {:ok, compiled} ->
        Heap.put_compiled(key, {:compiled, compiled})
        {:ok, apply_compiled(compiled, args)}

      {:error, _} ->
        Heap.put_compiled(key, :unsupported)
        :error
    end
  end

  defp apply_compiled({mod, name}, args), do: apply(mod, name, args)

  defp current_globals do
    case Heap.get_ctx() do
      %{globals: globals} -> globals
      _ -> Runtime.global_bindings()
    end
  end

  defp atom_name(atom_idx) do
    atoms =
      case Heap.get_ctx() do
        %{atoms: atoms} -> atoms
        _ -> Heap.get_atoms()
      end

    Scope.resolve_atom(atoms, atom_idx)
  end

  defp lower(fun, instructions) do
    entries = block_entries(instructions)
    slot_count = fun.arg_count + fun.var_count

    blocks =
      for start <- entries, into: [] do
        {start, block_form(start, fun.arg_count, slot_count, instructions, entries)}
      end

    case Enum.find(blocks, fn {_start, form} -> match?({:error, _}, form) end) do
      nil -> {:ok, {slot_count, Enum.map(blocks, &elem(&1, 1))}}
      {_start, error} -> error
    end
  end

  defp block_entries(instructions) do
    entries =
      instructions
      |> Enum.with_index()
      |> Enum.reduce(MapSet.new([0]), fn {{op, args}, idx}, acc ->
        case opcode_name(op) do
          {:ok, name} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
            [target] = args
            acc |> MapSet.put(target) |> MapSet.put(idx + 1)

          {:ok, name} when name in [:goto, :goto8, :goto16] ->
            [target] = args
            MapSet.put(acc, target)

          _ ->
            acc
        end
      end)

    entries
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp block_form(start, arg_count, slot_count, instructions, entries) do
    state = initial_state(slot_count)
    next_entry = next_entry(entries, start)

    with {:ok, body} <- lower_block(instructions, start, next_entry, arg_count, state) do
      {:function, @line, block_name(start), slot_count,
       [{:clause, @line, slot_vars(slot_count), [], body}]}
    end
  end

  defp next_entry(entries, start) do
    Enum.find(entries, &(&1 > start))
  end

  defp initial_state(slot_count) do
    slots =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, slot_var(idx)} end)

    %{
      body: [],
      slots: slots,
      stack: [],
      temp: 0
    }
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state)
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx, next_entry, arg_count, state.body}}
  end

  defp lower_block(_instructions, idx, idx, _arg_count, %{stack: []} = state) do
    {:ok, state.body ++ [local_call(block_name(idx), current_slots(state))]}
  end

  defp lower_block(_instructions, idx, idx, _arg_count, _state) do
    {:error, {:stack_not_empty_at_block_boundary, idx}}
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state) do
    instruction = Enum.at(instructions, idx)

    case lower_instruction(instruction, idx, next_entry, arg_count, state) do
      {:ok, next_state} -> lower_block(instructions, idx + 1, next_entry, arg_count, next_state)
      {:done, body} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  defp lower_instruction({op, args}, idx, next_entry, _arg_count, state) do
    name = opcode_name(op)

    case {name, args} do
      {{:ok, :push_i32}, [value]} ->
        {:ok, push(state, integer(value))}

      {{:ok, :push_i16}, [value]} ->
        {:ok, push(state, integer(value))}

      {{:ok, :push_i8}, [value]} ->
        {:ok, push(state, integer(value))}

      {{:ok, :push_minus1}, [_]} ->
        {:ok, push(state, integer(-1))}

      {{:ok, :push_0}, [_]} ->
        {:ok, push(state, integer(0))}

      {{:ok, :push_1}, [_]} ->
        {:ok, push(state, integer(1))}

      {{:ok, :push_2}, [_]} ->
        {:ok, push(state, integer(2))}

      {{:ok, :push_3}, [_]} ->
        {:ok, push(state, integer(3))}

      {{:ok, :push_4}, [_]} ->
        {:ok, push(state, integer(4))}

      {{:ok, :push_5}, [_]} ->
        {:ok, push(state, integer(5))}

      {{:ok, :push_6}, [_]} ->
        {:ok, push(state, integer(6))}

      {{:ok, :push_7}, [_]} ->
        {:ok, push(state, integer(7))}

      {{:ok, :push_true}, []} ->
        {:ok, push(state, atom(true))}

      {{:ok, :push_false}, []} ->
        {:ok, push(state, atom(false))}

      {{:ok, :null}, []} ->
        {:ok, push(state, atom(nil))}

      {{:ok, :undefined}, []} ->
        {:ok, push(state, atom(:undefined))}

      {{:ok, :push_empty_string}, []} ->
        {:error, {:unsupported_literal, :empty_string}}

      {{:ok, :object}, []} ->
        {:ok, push(state, compiler_call(:new_object, []))}

      {{:ok, :array_from}, [argc]} ->
        array_from_call(state, argc)

      {{:ok, :push_const}, [idx]} ->
        push_const(state, idx)

      {{:ok, :get_var}, [atom_idx]} ->
        {:ok, push(state, compiler_call(:get_var, [literal(atom_idx)]))}

      {{:ok, :get_var_undef}, [atom_idx]} ->
        {:ok, push(state, compiler_call(:get_var_undef, [literal(atom_idx)]))}

      {{:ok, :get_arg}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg0}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg1}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg2}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg3}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc0}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc1}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc2}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc3}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc8}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok, %{state | stack: [slot_expr(state, slot1), slot_expr(state, slot0) | state.stack]}}

      {{:ok, :get_loc_check}, [slot_idx]} ->
        {:ok,
         push(state, compiler_call(:ensure_initialized_local!, [slot_expr(state, slot_idx)]))}

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, put_slot(state, slot_idx, atom(@tdz))}

      {{:ok, :put_loc}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc0}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc1}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc2}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc3}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc8}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg0}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg1}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg2}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg3}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc_check}, [slot_idx]} ->
        assign_slot(state, slot_idx, false, :ensure_initialized_local!)

      {{:ok, :put_loc_check_init}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :set_loc}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc0}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc1}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc2}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc3}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg0}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg1}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg2}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg3}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :dup}, []} ->
        duplicate_top(state)

      {{:ok, :drop}, []} ->
        drop_top(state)

      {{:ok, :swap}, []} ->
        swap_top(state)

      {{:ok, :neg}, []} ->
        unary_local_call(state, :op_neg)

      {{:ok, :plus}, []} ->
        unary_local_call(state, :op_plus)

      {{:ok, :add}, []} ->
        binary_local_call(state, :op_add)

      {{:ok, :sub}, []} ->
        binary_local_call(state, :op_sub)

      {{:ok, :mul}, []} ->
        binary_local_call(state, :op_mul)

      {{:ok, :div}, []} ->
        binary_local_call(state, :op_div)

      {{:ok, :get_length}, []} ->
        unary_call(state, __MODULE__, :get_length)

      {{:ok, :get_array_el}, []} ->
        binary_call(state, QuickBEAM.BeamVM.Interpreter.Objects, :get_element)

      {{:ok, :get_field}, [atom_idx]} ->
        unary_call(state, __MODULE__, :get_field, [literal(atom_idx)])

      {{:ok, :get_field2}, [atom_idx]} ->
        get_field2(state, atom_idx)

      {{:ok, :put_field}, [atom_idx]} ->
        put_field_call(state, atom_idx)

      {{:ok, :define_field}, [atom_idx]} ->
        define_field_call(state, atom_idx)

      {{:ok, :put_array_el}, []} ->
        put_array_el_call(state)

      {{:ok, :to_propkey}, []} ->
        {:ok, state}

      {{:ok, :to_propkey2}, []} ->
        {:ok, state}

      {{:ok, :lt}, []} ->
        binary_local_call(state, :op_lt)

      {{:ok, :lte}, []} ->
        binary_local_call(state, :op_lte)

      {{:ok, :gt}, []} ->
        binary_local_call(state, :op_gt)

      {{:ok, :gte}, []} ->
        binary_local_call(state, :op_gte)

      {{:ok, :strict_eq}, []} ->
        binary_local_call(state, :op_strict_eq)

      {{:ok, :strict_neq}, []} ->
        binary_local_call(state, :op_strict_neq)

      {{:ok, :call}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call0}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call1}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call2}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call3}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :tail_call}, [argc]} ->
        invoke_tail_call(state, argc)

      {{:ok, :call_method}, [argc]} ->
        invoke_method_call(state, argc)

      {{:ok, :tail_call_method}, [argc]} ->
        invoke_tail_method_call(state, argc)

      {{:ok, :is_undefined_or_null}, []} ->
        unary_call(state, __MODULE__, :is_undefined_or_null)

      {{:ok, :if_false}, [target]} ->
        branch(state, idx, next_entry, target, false)

      {{:ok, :if_false8}, [target]} ->
        branch(state, idx, next_entry, target, false)

      {{:ok, :if_true}, [target]} ->
        branch(state, idx, next_entry, target, true)

      {{:ok, :if_true8}, [target]} ->
        branch(state, idx, next_entry, target, true)

      {{:ok, :goto}, [target]} ->
        goto(state, target)

      {{:ok, :goto8}, [target]} ->
        goto(state, target)

      {{:ok, :goto16}, [target]} ->
        goto(state, target)

      {{:ok, :return}, []} ->
        return_top(state)

      {{:ok, :return_undef}, []} ->
        {:done, state.body ++ [atom(:undefined)]}

      {{:ok, :nop}, []} ->
        {:ok, state}

      {{:error, _} = error, _} ->
        error

      {{:ok, name}, _} ->
        {:error, {:unsupported_opcode, name}}
    end
  end

  defp push_const(_state, idx), do: {:error, {:unsupported_const, idx}}

  defp assign_slot(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, state} <- pop(state) do
      expr = if wrapper, do: compiler_call(wrapper, [expr]), else: expr
      {bound, state} = bind(state, slot_name(idx, state.temp), expr)
      state = put_slot(state, idx, bound)
      state = if keep?, do: push(state, bound), else: state
      {:ok, state}
    end
  end

  defp duplicate_top(state) do
    with {:ok, expr, state} <- pop(state) do
      {bound, state} = bind(state, temp_name(state.temp), expr)
      {:ok, %{state | stack: [bound, bound | state.stack]}}
    end
  end

  defp drop_top(state) do
    case state.stack do
      [_ | rest] -> {:ok, %{state | stack: rest}}
      [] -> {:error, :stack_underflow}
    end
  end

  defp swap_top(%{stack: [a, b | rest]} = state), do: {:ok, %{state | stack: [b, a | rest]}}
  defp swap_top(_state), do: {:error, :stack_underflow}

  defp unary_call(state, mod, fun, extra_args \\ []) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [expr | extra_args]))}
    end
  end

  defp unary_local_call(state, fun) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, local_call(fun, [expr]))}
    end
  end

  defp binary_call(state, mod, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [left, right]))}
    end
  end

  defp binary_local_call(state, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, local_call(fun, [left, right]))}
    end
  end

  defp get_field2(state, atom_idx) do
    with {:ok, obj, state} <- pop(state) do
      field = remote_call(__MODULE__, :get_field, [obj, literal(atom_idx)])
      {:ok, %{state | stack: [field, obj | state.stack]}}
    end
  end

  defp put_field_call(state, atom_idx) do
    with {:ok, val, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok,
       %{state | body: state.body ++ [compiler_call(:put_field, [obj, literal(atom_idx), val])]}}
    end
  end

  defp define_field_call(state, atom_idx) do
    with {:ok, val, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok, push(state, compiler_call(:define_field, [obj, literal(atom_idx), val]))}
    end
  end

  defp put_array_el_call(state) do
    with {:ok, val, state} <- pop(state),
         {:ok, idx, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok, %{state | body: state.body ++ [compiler_call(:put_array_el, [obj, idx, val])]}}
    end
  end

  defp invoke_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state) do
      {:ok, push(state, compiler_call(:invoke_runtime, [fun, list_expr(Enum.reverse(args))]))}
    end
  end

  defp invoke_tail_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, %{stack: []} = state} <- pop(state) do
      {:done,
       state.body ++ [compiler_call(:invoke_runtime, [fun, list_expr(Enum.reverse(args))])]}
    else
      {:ok, _fun, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  defp invoke_method_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok,
       push(
         state,
         compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))])
       )}
    end
  end

  defp array_from_call(state, argc) do
    with {:ok, elems, state} <- pop_n(state, argc) do
      {:ok, push(state, compiler_call(:array_from, [list_expr(Enum.reverse(elems))]))}
    end
  end

  defp invoke_tail_method_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state),
         {:ok, obj, %{stack: []} = state} <- pop(state) do
      {:done,
       state.body ++
         [compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))])]}
    else
      {:ok, _obj, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  defp goto(%{stack: []} = state, target) do
    {:done, state.body ++ [local_call(block_name(target), current_slots(state))]}
  end

  defp goto(_state, target), do: {:error, {:stack_not_empty_at_goto, target}}

  defp branch(%{stack: stack}, idx, next_entry, target, sense) when stack == [] do
    {:error, {:missing_branch_condition, idx, target, sense, next_entry}}
  end

  defp branch(state, _idx, next_entry, target, sense) when is_nil(next_entry) do
    {:error, {:missing_fallthrough_block, target, sense, state.body}}
  end

  defp branch(state, _idx, next_entry, target, sense) do
    with {:ok, cond_expr, %{stack: []} = state} <- pop(state) do
      truthy = remote_call(Values, :truthy?, [cond_expr])
      false_body = [local_call(block_name(target), current_slots(state))]
      true_body = [local_call(block_name(next_entry), current_slots(state))]

      body =
        case sense do
          false -> state.body ++ [case_expr(truthy, false_body, true_body)]
          true -> state.body ++ [case_expr(truthy, true_body, false_body)]
        end

      {:done, body}
    else
      {:ok, _cond, _state} -> {:error, {:stack_not_empty_after_branch, target}}
      {:error, _} = error -> error
    end
  end

  defp return_top(state) do
    with {:ok, expr, %{stack: []}} <- pop(state) do
      {:done, state.body ++ [expr]}
    else
      {:ok, _expr, _state} -> {:error, :stack_not_empty_on_return}
      {:error, _} = error -> error
    end
  end

  defp pop(%{stack: [expr | rest]} = state), do: {:ok, expr, %{state | stack: rest}}
  defp pop(_state), do: {:error, :stack_underflow}

  defp pop_n(state, 0), do: {:ok, [], state}

  defp pop_n(state, count) when count > 0 do
    with {:ok, expr, state} <- pop(state),
         {:ok, rest, state} <- pop_n(state, count - 1) do
      {:ok, [expr | rest], state}
    end
  end

  defp push(state, expr), do: %{state | stack: [expr | state.stack]}

  defp put_slot(state, idx, expr), do: %{state | slots: Map.put(state.slots, idx, expr)}

  defp slot_expr(state, idx), do: Map.get(state.slots, idx, atom(:undefined))

  defp bind(state, name, expr) do
    var = var(name)
    {var, %{state | body: state.body ++ [match(var, expr)], temp: state.temp + 1}}
  end

  defp compile_forms(module, entry, arity, slot_count, block_forms) do
    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}]},
      entry_form(entry, arity, slot_count)
      | helper_forms() ++ block_forms
    ]

    case :compile.forms(forms, [:binary, :return_errors, :return_warnings]) do
      {:ok, mod, binary} -> {:ok, mod, binary}
      {:ok, mod, binary, _warnings} -> {:ok, mod, binary}
      {:error, errors, _warnings} -> {:error, {:compile_failed, errors}}
    end
  end

  defp entry_form(entry, arity, slot_count) do
    args = slot_vars(arity)

    locals =
      if slot_count <= arity,
        do: [],
        else: Enum.map(arity..(slot_count - 1), fn _ -> atom(:undefined) end)

    body = [
      local_call(block_name(0), args ++ locals)
    ]

    {:function, @line, entry, arity, [{:clause, @line, args, [], body}]}
  end

  defp current_slots(state), do: ordered_slot_values(state.slots)

  defp helper_forms do
    [
      guarded_binary_helper(:op_add, :+, Values, :add),
      guarded_binary_helper(:op_sub, :-, Values, :sub),
      guarded_binary_helper(:op_mul, :*, Values, :mul),
      guarded_binary_helper(:op_div, :/, Values, :div),
      guarded_binary_helper(:op_lt, :<, Values, :lt),
      guarded_binary_helper(:op_lte, :"=<", Values, :lte),
      guarded_binary_helper(:op_gt, :>, Values, :gt),
      guarded_binary_helper(:op_gte, :>=, Values, :gte),
      strict_eq_helper(),
      strict_neq_helper(),
      guarded_unary_helper(:op_neg, :-, Values, :neg),
      unary_fallback_helper(:op_plus, Values, :to_number)
    ]
  end

  defp guarded_binary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    {:function, @line, name, 2,
     [
       {:clause, @line, [a, b], [integer_guards(a, b)], [{:op, @line, op, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])]}
     ]}
  end

  defp guarded_unary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")

    {:function, @line, name, 1,
     [
       {:clause, @line, [a], [[integer_guard(a)]], [{:op, @line, op, a}]},
       {:clause, @line, [a], [], [remote_call(fallback_mod, fallback_fun, [a])]}
     ]}
  end

  defp unary_fallback_helper(name, fallback_mod, fallback_fun) do
    a = var("A")

    {:function, @line, name, 1,
     [
       {:clause, @line, [a], [[integer_guard(a)]], [a]},
       {:clause, @line, [a], [], [remote_call(fallback_mod, fallback_fun, [a])]}
     ]}
  end

  defp strict_eq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_strict_eq, 2,
     [
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(Values, :strict_eq, [a, b])]}
     ]}
  end

  defp strict_neq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_strict_neq, 2,
     [
       {:clause, @line, [a, b], [], [{:op, @line, :not, local_call(:op_strict_eq, [a, b])}]}
     ]}
  end

  defp integer_guards(a, b), do: [integer_guard(a), integer_guard(b)]
  defp number_guards(a, b), do: [number_guard(a), number_guard(b)]

  defp integer_guard(expr), do: {:call, @line, {:atom, @line, :is_integer}, [expr]}
  defp number_guard(expr), do: {:call, @line, {:atom, @line, :is_number}, [expr]}

  defp ordered_slot_values(slots) do
    slots
    |> Enum.sort_by(fn {idx, _expr} -> idx end)
    |> Enum.map(fn {_idx, expr} -> expr end)
  end

  defp case_expr(expr, false_body, true_body) do
    {:case, @line, expr,
     [
       {:clause, @line, [atom(false)], [], false_body},
       {:clause, @line, [atom(true)], [], true_body}
     ]}
  end

  defp opcode_name(op) do
    case Opcodes.info(op) do
      {name, _size, _pop, _push, _fmt} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, op}}
    end
  end

  defp module_name(fun) do
    hash =
      :crypto.hash(:sha256, [fun.byte_code, <<fun.arg_count::32, fun.var_count::32>>])
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.BeamVM.Compiled, "F#{hash}")
  end

  defp entry_name, do: :run

  defp block_name(idx), do: String.to_atom("block_#{idx}")
  defp slot_name(idx, n), do: "Slot#{idx}_#{n}"
  defp temp_name(n), do: "Tmp#{n}"

  defp slot_var(idx), do: var("Slot#{idx}")

  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)

  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  defp var(name) when is_atom(name), do: {:var, @line, name}

  defp integer(value), do: {:integer, @line, value}
  defp atom(value), do: {:atom, @line, value}
  defp literal(value), do: :erl_parse.abstract(value)
  defp match(left, right), do: {:match, @line, left, right}

  defp list_expr([]), do: {nil, @line}
  defp list_expr([head | tail]), do: {:cons, @line, head, list_expr(tail)}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}

  defp compiler_call(fun, args), do: remote_call(__MODULE__, fun, args)
end
