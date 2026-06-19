defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings do
  @moduledoc "Variable, global binding, and reference helpers used by BEAM-compiled JavaScript."

  alias QuickBEAM.VM.{GlobalEnvironment, Heap, Invocation, JSThrow, Names, RuntimeState, Value}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Interpreter.{Closures, Context}
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Get, Put}

  @doc "Reads a variable binding or throws a JavaScript ReferenceError when absent."
  def get_var(ctx, "arguments"), do: arguments_object(ctx)
  def get_var(ctx, name) when is_binary(name), do: fetch_ctx_var(ctx, name)

  def get_var(ctx, atom_idx),
    do: get_var(ctx, Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx))

  def get_var(name) when is_binary(name) do
    case GlobalEnvironment.fetch(name) do
      {:found, value} -> value
      :not_found -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  def get_var(atom_idx), do: get_var(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_undef(ctx, "arguments"), do: arguments_object(ctx)

  def get_var_undef(ctx, name) when is_binary(name),
    do: get_global_undef(RuntimeContext.globals(ctx), name)

  def get_var_undef(ctx, atom_idx),
    do: get_var_undef(ctx, Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx))

  def get_var_undef(name) when is_binary(name), do: GlobalEnvironment.get(name, :undefined)

  def get_var_undef(atom_idx),
    do: get_var_undef(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_global(globals, name) do
    case fetch_global_binding(globals, name) do
      {:ok, :__tdz__} -> JSThrow.reference_error!("#{name} is not initialized")
      {:ok, value} -> value
      :error -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  @doc "Reads a global binding and returns `:undefined` when absent."
  def get_global_undef(globals, name) do
    case fetch_global_binding(globals, name) do
      {:ok, value} -> value
      :error -> :undefined
    end
  end

  def delete_var(ctx, atom_idx) do
    name = Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx)
    builtins = Heap.get_builtin_names() || MapSet.new()

    case Map.fetch(RuntimeContext.globals(ctx), name) do
      {:ok, _value} when name in ["NaN", "undefined", "Infinity", "globalThis"] -> false
      {:ok, {:builtin, _, _}} -> true
      {:ok, _value} -> MapSet.member?(builtins, name)
      :error -> true
    end
  end

  @doc "Reads the value referenced by a compiled variable reference."
  def get_var_ref(ctx, idx), do: read_var_ref(current_var_ref(ctx, idx))
  def get_var_ref_check(ctx, idx), do: checked_var_ref(ctx, idx)
  def get_var_ref(idx), do: read_var_ref(current_var_ref(idx))
  def get_var_ref_check(idx), do: checked_var_ref(idx)

  @doc "Invokes a callable stored in a variable reference."
  def invoke_var_ref(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), args)

  def invoke_var_ref0(ctx, idx), do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [])

  def invoke_var_ref1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0])

  @doc "Invokes a callable variable reference with two arguments."
  def invoke_var_ref2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1])

  def invoke_var_ref3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), args)

  @doc "Checks and invokes a callable variable reference with no arguments."
  def invoke_var_ref_check0(ctx, idx),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [])

  def invoke_var_ref_check1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0])

  def invoke_var_ref_check2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1])

  @doc "Checks and invokes a callable variable reference with three arguments."
  def invoke_var_ref_check3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1, arg2])

  def invoke_var_ref(idx, args), do: Invocation.invoke_runtime(get_var_ref(idx), args)
  def invoke_var_ref0(idx), do: Invocation.invoke_runtime(get_var_ref(idx), [])
  def invoke_var_ref1(idx, arg0), do: Invocation.invoke_runtime(get_var_ref(idx), [arg0])

  def invoke_var_ref2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1])

  def invoke_var_ref3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(idx, args), do: Invocation.invoke_runtime(checked_var_ref(idx), args)
  def invoke_var_ref_check0(idx), do: Invocation.invoke_runtime(checked_var_ref(idx), [])

  def invoke_var_ref_check1(idx, arg0),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0])

  def invoke_var_ref_check2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0, arg1])

  def invoke_var_ref_check3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0, arg1, arg2])

  def put_var_ref(ctx, idx, value) do
    write_var_ref(current_var_ref(ctx, idx), value)
    :ok
  end

  def put_var_ref_check_init(ctx, idx, value) do
    ref = current_var_ref(ctx, idx)

    if var_ref_name(ctx, idx) == "this" and match?({:obj, _}, read_var_ref(ref)) do
      JSThrow.reference_error!("this is already initialized")
    end

    write_var_ref(ref, value)
    :ok
  end

  @doc "Writes a value through a compiled variable reference and returns the value."
  def set_var_ref(ctx, idx, value) do
    put_var_ref(ctx, idx, value)
    value
  end

  def put_var_ref(idx, value) do
    write_var_ref(current_var_ref(idx), value)
    :ok
  end

  def set_var_ref(idx, value) do
    put_var_ref(idx, value)
    value
  end

  def make_var_ref(ctx, atom_idx),
    do: {:global_ref, Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx)}

  @doc "Returns or creates a mutable reference cell for an existing variable reference."
  def make_var_ref_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      {:cell, _} = cell ->
        cell

      value ->
        ref = make_ref()
        Heap.put_cell(ref, value)
        {:cell, ref}
    end
  end

  @doc "Creates a mutable reference cell for a local slot value."
  def make_loc_ref(ctx \\ nil, idx, value \\ :undefined)

  def make_loc_ref(_ctx, _idx, value) do
    ref = make_ref()
    Heap.put_cell(ref, value)
    {:cell, ref}
  end

  def make_arg_ref(ctx \\ nil, idx) do
    ref = make_ref()
    value = ctx |> RuntimeContext.arg_buf() |> elem(idx)
    Heap.put_cell(ref, value)
    {:cell, ref}
  end

  @doc "Reads the value from a reference cell or object-property reference."
  def get_ref_value(ctx \\ nil, key, ref)
  def get_ref_value(_ctx, _key, {:cell, _} = cell), do: Closures.read_cell(cell)
  def get_ref_value(ctx, _key, {:global_ref, name}), do: get_var_undef(ctx, name)
  def get_ref_value(_ctx, key, object) when is_binary(key), do: Get.get(object, key)
  def get_ref_value(_ctx, _key, _), do: :undefined

  def put_ref_value(ctx \\ nil, value, key, ref)

  def put_ref_value(ctx, value, _key, {:cell, _} = cell) do
    Closures.write_cell(cell, value)
    ctx
  end

  def put_ref_value(ctx, value, _key, {:global_ref, name}),
    do: GlobalEnvironment.put(RuntimeContext.ensure(ctx), name, value)

  def put_ref_value(ctx, value, key, object) when is_binary(key) do
    Put.put(object, key, value)
    ctx
  end

  def put_ref_value(ctx, _value, _key, _), do: ctx

  @doc "Reads a variable from a compiled context or throws when absent."
  def fetch_ctx_var(ctx, name) do
    case fetch_global_binding(RuntimeContext.globals(ctx), name) do
      {:ok, :__tdz__} -> JSThrow.reference_error!("#{name} is not initialized")
      {:ok, value} -> value
      :error -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  def current_strict_mode?(ctx), do: Value.strict_context?(ctx)

  defp arguments_object(ctx) do
    current_func = RuntimeContext.current_func(ctx)
    key = RuntimeState.compiled_arguments_object_key(current_func, RuntimeContext.arg_buf(ctx))

    case RuntimeState.get_arguments_object(key) do
      nil ->
        arguments =
          Heap.wrap_arguments(Tuple.to_list(RuntimeContext.arg_buf(ctx)),
            strict: current_strict_mode?(ctx),
            callee: current_func
          )

        RuntimeState.put_arguments_object(key, arguments)

      arguments ->
        arguments
    end
  end

  defp fetch_global_binding(globals, name) do
    persistent = Heap.get_persistent_globals() || %{}

    if Map.has_key?(persistent, name) do
      Map.fetch(persistent, name)
    else
      Map.fetch(globals, name)
    end
  end

  defp current_var_ref(idx), do: current_var_ref(current_context(), idx)

  defp current_var_ref(ctx, idx) do
    case RuntimeContext.current_func(ctx) do
      {:closure, captured, %QuickBEAM.VM.Function{} = fun} ->
        case capture_keys_tuple(fun) do
          keys when idx >= 0 and idx < tuple_size(keys) ->
            Map.get(captured, elem(keys, idx), :undefined)

          _ ->
            :undefined
        end

      _ ->
        :undefined
    end
  end

  defp capture_keys_tuple(%QuickBEAM.VM.Function{closure_vars: vars} = fun) do
    case Heap.get_capture_keys(fun) do
      nil ->
        tuple = vars |> Enum.map(&closure_capture_key/1) |> List.to_tuple()
        Heap.put_capture_keys(fun, tuple)
        tuple

      cached ->
        cached
    end
  end

  defp read_var_ref({:cell, _} = cell), do: Closures.read_cell(cell)
  defp read_var_ref(other), do: other

  defp checked_var_ref(idx), do: checked_var_ref(current_context(), idx)

  defp checked_var_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      :__tdz__ ->
        JSThrow.reference_error!(var_ref_error_message(ctx, idx))

      {:cell, _} = cell ->
        value = Closures.read_cell(cell)

        if value == :__tdz__ do
          JSThrow.reference_error!(var_ref_error_message(ctx, idx))
        end

        value

      value ->
        value
    end
  end

  defp write_var_ref({:cell, _} = cell, value), do: Closures.write_cell(cell, value)
  defp write_var_ref(_, _), do: :ok

  defp var_ref_error_message(ctx, idx) do
    if var_ref_name(ctx, idx) == "this" do
      "this is not initialized"
    else
      "Cannot access variable before initialization"
    end
  end

  defp var_ref_name(ctx, idx) do
    case RuntimeContext.current_func(ctx) do
      {:closure, _, %QuickBEAM.VM.Function{closure_vars: vars}}
      when idx >= 0 and idx < length(vars) ->
        vars
        |> Enum.at(idx)
        |> Map.get(:name)
        |> Names.resolve_display_name(RuntimeContext.atoms(ctx))

      _ ->
        nil
    end
  end

  defp closure_capture_key(%{closure_type: type, var_idx: idx}), do: {type, idx}

  defp current_context do
    case RuntimeState.current() do
      %Context{} = ctx -> ctx
      map when is_map(map) -> RuntimeContext.struct_context(map)
      _ -> %Context{atoms: Heap.get_atoms(), globals: GlobalEnvironment.base_globals()}
    end
  end
end
