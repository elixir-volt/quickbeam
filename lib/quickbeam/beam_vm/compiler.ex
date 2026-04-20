defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Heap, Opcodes}
  alias QuickBEAM.BeamVM.Interpreter.Values

  @line 1
  @tdz :__tdz__

  @type compiled_fun :: {module(), atom()}

  def invoke(%Bytecode.Function{closure_vars: []} = fun, args) do
    key = {fun.byte_code, fun.arg_count}

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
             {:ok, body} <- lower(instructions, fun.arg_count, initial_state()),
             {:ok, _module, binary} <- compile_forms(module, entry, fun.arg_count, body),
             {:module, ^module} <- :code.load_binary(module, ~c"quickbeam_compiler", binary) do
          {:ok, {module, entry}}
        else
          {:error, _} = error -> error
          {:ok, _module, _binary, _warnings} = ok -> normalize_compile_result(ok)
          {:module, module, _binary, _warnings} -> {:ok, {module, entry}}
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

  defp initial_state do
    %{body: [], locals: %{}, stack: [], temp: 0}
  end

  defp lower(instructions, arg_count, state) do
    Enum.reduce_while(instructions, {:ok, state}, fn instruction, {:ok, current_state} ->
      case lower_instruction(instruction, arg_count, current_state) do
        {:ok, next_state} ->
          {:cont, {:ok, next_state}}

        {:return, body} ->
          {:halt, {:ok, body}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, %{body: body}} -> {:error, {:missing_return, body}}
      other -> other
    end
  end

  defp lower_instruction({op, args}, _arg_count, state) do
    name = opcode_name(op)

    case {name, args} do
      {{:ok, :push_i32}, [value]} ->
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

      {{:ok, :push_const}, [idx]} ->
        push_const(state, idx)

      {{:ok, :get_arg}, [idx]} ->
        {:ok, push(state, arg_var(idx))}

      {{:ok, :get_arg0}, [idx]} ->
        {:ok, push(state, arg_var(idx))}

      {{:ok, :get_arg1}, [idx]} ->
        {:ok, push(state, arg_var(idx))}

      {{:ok, :get_arg2}, [idx]} ->
        {:ok, push(state, arg_var(idx))}

      {{:ok, :get_arg3}, [idx]} ->
        {:ok, push(state, arg_var(idx))}

      {{:ok, :get_loc}, [idx]} ->
        {:ok, push(state, local_expr(state, idx))}

      {{:ok, :get_loc0}, [idx]} ->
        {:ok, push(state, local_expr(state, idx))}

      {{:ok, :get_loc1}, [idx]} ->
        {:ok, push(state, local_expr(state, idx))}

      {{:ok, :get_loc2}, [idx]} ->
        {:ok, push(state, local_expr(state, idx))}

      {{:ok, :get_loc3}, [idx]} ->
        {:ok, push(state, local_expr(state, idx))}

      {{:ok, :get_loc8}, [idx]} ->
        {:ok, push(state, local_expr(state, idx))}

      {{:ok, :get_loc_check}, [idx]} ->
        {:ok, push(state, compiler_call(:ensure_initialized_local!, [local_expr(state, idx)]))}

      {{:ok, :set_loc_uninitialized}, [idx]} ->
        {:ok, put_local(state, idx, atom(@tdz))}

      {{:ok, :put_loc}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :put_loc0}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :put_loc1}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :put_loc2}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :put_loc3}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :put_loc8}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :put_loc_check}, [idx]} ->
        assign_local(state, idx, false, :ensure_initialized_local!)

      {{:ok, :put_loc_check_init}, [idx]} ->
        assign_local(state, idx, false)

      {{:ok, :set_loc}, [idx]} ->
        assign_local(state, idx, true)

      {{:ok, :set_loc0}, [idx]} ->
        assign_local(state, idx, true)

      {{:ok, :set_loc1}, [idx]} ->
        assign_local(state, idx, true)

      {{:ok, :set_loc2}, [idx]} ->
        assign_local(state, idx, true)

      {{:ok, :set_loc3}, [idx]} ->
        assign_local(state, idx, true)

      {{:ok, :dup}, []} ->
        duplicate_top(state)

      {{:ok, :drop}, []} ->
        drop_top(state)

      {{:ok, :neg}, []} ->
        unary_call(state, Values, :neg)

      {{:ok, :plus}, []} ->
        unary_call(state, Values, :to_number)

      {{:ok, :add}, []} ->
        binary_call(state, Values, :add)

      {{:ok, :sub}, []} ->
        binary_call(state, Values, :sub)

      {{:ok, :mul}, []} ->
        binary_call(state, Values, :mul)

      {{:ok, :div}, []} ->
        binary_call(state, Values, :div)

      {{:ok, :lt}, []} ->
        binary_call(state, Values, :lt)

      {{:ok, :lte}, []} ->
        binary_call(state, Values, :lte)

      {{:ok, :gt}, []} ->
        binary_call(state, Values, :gt)

      {{:ok, :gte}, []} ->
        binary_call(state, Values, :gte)

      {{:ok, :strict_eq}, []} ->
        binary_call(state, Values, :strict_eq)

      {{:ok, :strict_neq}, []} ->
        binary_call(state, __MODULE__, :strict_neq)

      {{:ok, :return}, []} ->
        return_top(state)

      {{:ok, :return_undef}, []} ->
        {:return, state.body ++ [atom(:undefined)]}

      {{:ok, :nop}, []} ->
        {:ok, state}

      {{:error, _} = error, _} ->
        error

      {{:ok, name}, _} ->
        {:error, {:unsupported_opcode, name}}
    end
  end

  defp push_const(_state, idx), do: {:error, {:unsupported_const, idx}}

  defp assign_local(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, state} <- pop(state) do
      expr = if wrapper, do: compiler_call(wrapper, [expr]), else: expr
      {bound, state} = bind(state, local_name(idx, state.temp), expr)
      state = put_local(state, idx, bound)
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

  defp unary_call(state, mod, fun) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [expr]))}
    end
  end

  defp binary_call(state, mod, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [left, right]))}
    end
  end

  defp return_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:return, state.body ++ [expr]}
    end
  end

  defp pop(%{stack: [expr | rest]} = state), do: {:ok, expr, %{state | stack: rest}}
  defp pop(_state), do: {:error, :stack_underflow}

  defp push(state, expr), do: %{state | stack: [expr | state.stack]}

  defp put_local(state, idx, expr), do: %{state | locals: Map.put(state.locals, idx, expr)}

  defp local_expr(state, idx), do: Map.get(state.locals, idx, atom(:undefined))

  defp bind(state, name, expr) do
    var = var(name)
    {var, %{state | body: state.body ++ [match(var, expr)], temp: state.temp + 1}}
  end

  defp compile_forms(module, entry, arity, body) do
    args = if arity == 0, do: [], else: Enum.map(0..(arity - 1), &arg_var/1)

    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}]},
      {:function, @line, entry, arity, [{:clause, @line, args, [], body}]}
    ]

    case :compile.forms(forms, [:binary, :return_errors, :return_warnings]) do
      {:ok, mod, binary} -> {:ok, mod, binary}
      {:ok, mod, binary, _warnings} -> {:ok, mod, binary}
      {:error, errors, _warnings} -> {:error, {:compile_failed, errors}}
    end
  end

  defp normalize_compile_result({:ok, mod, _binary, _warnings}), do: {:ok, {mod, entry_name()}}

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

  defp arg_var(idx), do: var("Arg#{idx}")
  defp local_name(idx, n), do: "Loc#{idx}_#{n}"
  defp temp_name(n), do: "Tmp#{n}"

  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  defp var(name) when is_atom(name), do: {:var, @line, name}

  defp integer(value), do: {:integer, @line, value}
  defp atom(value), do: {:atom, @line, value}
  defp match(left, right), do: {:match, @line, left, right}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp compiler_call(fun, args), do: remote_call(__MODULE__, fun, args)
end
