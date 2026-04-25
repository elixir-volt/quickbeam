defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Variables do
  @moduledoc "Variable access, closures, captures, and var-ref operations."

  alias QuickBEAM.VM.{Bytecode, GlobalEnv, Heap, Invocation, JSThrow, Names}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Coercion
  alias QuickBEAM.VM.Interpreter.{Closures, Context}
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.Private

  # --- ctx-accepting (BEAM JIT path) ---

  def get_var(ctx, name) when is_binary(name), do: fetch_ctx_var(ctx, name)

  def get_var(ctx, atom_idx),
    do: fetch_ctx_var(ctx, Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx))

  def get_global(globals, name) do
    case Map.fetch(globals, name) do
      {:ok, val} -> val
      :error -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  def get_global_undef(globals, name), do: Map.get(globals, name, :undefined)

  def get_var_undef(ctx, name) when is_binary(name),
    do: GlobalEnv.get(Coercion.context_globals(ctx), name, :undefined)

  def get_var_undef(ctx, atom_idx),
    do: get_var_undef(ctx, Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx))

  def push_atom_value(ctx, atom_idx),
    do: Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx)

  def private_symbol(_ctx, name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(ctx, atom_idx),
    do: Private.private_symbol(Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx))

  def get_var_ref(ctx, idx), do: read_var_ref(current_var_ref(ctx, idx))
  def get_var_ref_check(ctx, idx), do: checked_var_ref(ctx, idx)

  def get_capture(ctx, key) do
    case Coercion.context_current_func(ctx) do
      {:closure, captured, _} -> read_var_ref(Map.get(captured, key, :undefined))
      _ -> :undefined
    end
  end

  def invoke_var_ref(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), args)

  def invoke_var_ref0(ctx, idx), do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [])

  def invoke_var_ref1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0])

  def invoke_var_ref2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1])

  def invoke_var_ref3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, get_var_ref(ctx, idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(ctx, idx, args),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), args)

  def invoke_var_ref_check0(ctx, idx),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [])

  def invoke_var_ref_check1(ctx, idx, arg0),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0])

  def invoke_var_ref_check2(ctx, idx, arg0, arg1),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1])

  def invoke_var_ref_check3(ctx, idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(ctx, checked_var_ref(ctx, idx), [arg0, arg1, arg2])

  def put_var_ref(ctx, idx, val) do
    write_var_ref(current_var_ref(ctx, idx), val)
    :ok
  end

  def set_var_ref(ctx, idx, val) do
    put_var_ref(ctx, idx, val)
    val
  end

  def put_capture(ctx, key, val) do
    case Coercion.context_current_func(ctx) do
      {:closure, captured, _} -> write_var_ref(Map.get(captured, key, :undefined), val)
      _ -> :ok
    end

    :ok
  end

  def set_capture(ctx, key, val) do
    put_capture(ctx, key, val)
    val
  end

  def make_var_ref(ctx, atom_idx) do
    name = Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx)
    val = Map.get(Coercion.context_globals(ctx), name, :undefined)
    ref = make_ref()
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  def make_var_ref_ref(ctx, idx) do
    case current_var_ref(ctx, idx) do
      {:cell, _} = cell ->
        cell

      val ->
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}
    end
  end

  # --- ctxless (InvokeContext process-dictionary path) ---

  def get_var(name) when is_binary(name) do
    case GlobalEnv.fetch(name) do
      {:found, val} -> val
      :not_found -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  def get_var(atom_idx),
    do: get_var(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_undef(name) when is_binary(name), do: GlobalEnv.get(name, :undefined)

  def get_var_undef(atom_idx),
    do: get_var_undef(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def push_atom_value(atom_idx), do: Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)

  def private_symbol(name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(atom_idx),
    do: Private.private_symbol(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_var_ref(idx), do: read_var_ref(current_var_ref(idx))
  def get_var_ref_check(idx), do: checked_var_ref(idx)

  def invoke_var_ref(idx, args), do: Invocation.invoke_runtime(get_var_ref(idx), args)
  def invoke_var_ref0(idx), do: Invocation.invoke_runtime(get_var_ref(idx), [])
  def invoke_var_ref1(idx, arg0), do: Invocation.invoke_runtime(get_var_ref(idx), [arg0])

  def invoke_var_ref2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1])

  def invoke_var_ref3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(get_var_ref(idx), [arg0, arg1, arg2])

  def invoke_var_ref_check(idx, args),
    do: Invocation.invoke_runtime(checked_var_ref(idx), args)

  def invoke_var_ref_check0(idx), do: Invocation.invoke_runtime(checked_var_ref(idx), [])

  def invoke_var_ref_check1(idx, arg0),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0])

  def invoke_var_ref_check2(idx, arg0, arg1),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0, arg1])

  def invoke_var_ref_check3(idx, arg0, arg1, arg2),
    do: Invocation.invoke_runtime(checked_var_ref(idx), [arg0, arg1, arg2])

  def put_var_ref(idx, val) do
    write_var_ref(current_var_ref(idx), val)
    :ok
  end

  def set_var_ref(idx, val) do
    put_var_ref(idx, val)
    val
  end

  def make_loc_ref(_ctx \\ nil, _idx) do
    ref = make_ref()
    Heap.put_cell(ref, :undefined)
    {:cell, ref}
  end

  def make_arg_ref(_ctx \\ nil, idx) do
    ref = make_ref()
    val = elem(InvokeContext.current_arg_buf(), idx)
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  def get_ref_value(_ctx \\ nil, ref)
  def get_ref_value(_ctx, {:cell, _} = cell), do: Closures.read_cell(cell)
  def get_ref_value(_ctx, _), do: :undefined

  def put_ref_value(_ctx \\ nil, val, ref)

  def put_ref_value(_ctx, val, {:cell, _} = cell) do
    Closures.write_cell(cell, val)
    val
  end

  def put_ref_value(_ctx, val, _), do: val

  # --- shared helpers ---

  def fetch_ctx_var(ctx, name) do
    case GlobalEnv.fetch(Coercion.context_globals(ctx), name) do
      {:found, val} -> val
      :not_found -> JSThrow.reference_error!("#{name} is not defined")
    end
  end

  defp current_var_ref(idx), do: current_var_ref(current_context(), idx)

  defp current_var_ref(ctx, idx) do
    case Coercion.context_current_func(ctx) do
      {:closure, captured, %Bytecode.Function{} = fun} ->
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

  defp capture_keys_tuple(%Bytecode.Function{closure_vars: vars} = fun) do
    case Heap.get_capture_keys(fun.byte_code) do
      nil ->
        tuple = vars |> Enum.map(&closure_capture_key/1) |> List.to_tuple()
        Heap.put_capture_keys(fun.byte_code, tuple)
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
        val = Closures.read_cell(cell)

        if val == :__tdz__ and var_ref_name(ctx, idx) == "this" and
             derived_this_uninitialized?(ctx) do
          JSThrow.reference_error!("this is not initialized")
        end

        val

      val ->
        val
    end
  end

  defp write_var_ref({:cell, _} = cell, val), do: Closures.write_cell(cell, val)
  defp write_var_ref(_, _), do: :ok

  defp var_ref_error_message(ctx, idx) do
    if var_ref_name(ctx, idx) == "this" and derived_this_uninitialized?(ctx) do
      "this is not initialized"
    else
      "Cannot access variable before initialization"
    end
  end

  defp var_ref_name(ctx, idx) do
    case Coercion.context_current_func(ctx) do
      {:closure, _, %Bytecode.Function{closure_vars: vars}}
      when idx >= 0 and idx < length(vars) ->
        vars
        |> Enum.at(idx)
        |> Map.get(:name)
        |> Names.resolve_display_name(Coercion.context_atoms(ctx))

      _ ->
        nil
    end
  end

  defp closure_capture_key(%{closure_type: type, var_idx: idx}), do: {type, idx}

  defp derived_this_uninitialized?(ctx) do
    case Coercion.context_this(ctx) do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        true

      _ ->
        false
    end
  end

  defp current_context do
    case Heap.get_ctx() do
      %Context{} = ctx -> ctx
      map when is_map(map) -> Coercion.context_struct(map)
      _ -> %Context{atoms: Heap.get_atoms(), globals: GlobalEnv.base_globals()}
    end
  end
end
