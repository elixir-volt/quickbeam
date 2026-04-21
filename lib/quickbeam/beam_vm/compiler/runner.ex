defmodule QuickBEAM.BeamVM.Compiler.Runner do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap, Runtime, Semantics}
  alias QuickBEAM.BeamVM.Compiler
  alias QuickBEAM.BeamVM.Interpreter.Context

  @fast_ctx_keys [
    :qb_ctx_atoms,
    :qb_ctx_globals,
    :qb_current_func,
    :qb_arg_buf,
    :qb_this,
    :qb_new_target,
    :qb_home_object_current,
    :qb_super_current
  ]
  @missing :__qb_missing__

  def invoke(%Bytecode.Function{} = fun, args), do: invoke_target(fun, fun, args, %{})

  def invoke({:closure, _captured, %Bytecode.Function{} = fun} = closure, args),
    do: invoke_target(closure, fun, args, %{})

  def invoke(_, _), do: :error

  def invoke_with_receiver(%Bytecode.Function{} = fun, args, this_obj),
    do: invoke_target(fun, fun, args, %{this: this_obj})

  def invoke_with_receiver(
        {:closure, _captured, %Bytecode.Function{} = fun} = closure,
        args,
        this_obj
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj})

  def invoke_with_receiver(_, _, _), do: :error

  def invoke_constructor(%Bytecode.Function{} = fun, args, this_obj, new_target),
    do: invoke_target(fun, fun, args, %{this: this_obj, new_target: new_target})

  def invoke_constructor(
        {:closure, _captured, %Bytecode.Function{} = fun} = closure,
        args,
        this_obj,
        new_target
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj, new_target: new_target})

  def invoke_constructor(_, _, _, _), do: :error

  defp invoke_target(current_func, %Bytecode.Function{} = fun, args, ctx_overrides) do
    key = {fun.byte_code, fun.arg_count}
    args = normalize_args(args, fun.arg_count)

    if atoms = Process.get({:qb_fn_atoms, fun.byte_code}) do
      Heap.put_atoms(atoms)
    end

    with_compiled_ctx(current_func, args, ctx_overrides, fn ->
      case Heap.get_compiled(key) do
        {:compiled, {mod, name}} -> {:ok, apply(mod, name, args)}
        :unsupported -> :error
        nil -> compile_and_invoke(fun, args, key)
      end
    end)
  end

  defp compile_and_invoke(fun, args, key) do
    case Compiler.compile(fun) do
      {:ok, compiled} ->
        Heap.put_compiled(key, {:compiled, compiled})
        {:ok, apply_compiled(compiled, args)}

      {:error, _} ->
        Heap.put_compiled(key, :unsupported)
        :error
    end
  end

  defp apply_compiled({mod, name}, args), do: apply(mod, name, args)

  defp with_compiled_ctx(current_func, args, ctx_overrides, callback) do
    prev_ctx = Heap.get_ctx()

    base_ctx =
      case prev_ctx do
        %Context{} = ctx ->
          if ctx.globals == %{}, do: %{ctx | globals: Runtime.global_bindings()}, else: ctx

        nil ->
          %Context{atoms: Heap.get_atoms(), globals: Runtime.global_bindings()}

        map ->
          ctx = struct(Context, Map.merge(Map.from_struct(%Context{}), map))
          if ctx.globals == %{}, do: %{ctx | globals: Runtime.global_bindings()}, else: ctx
      end

    next_ctx =
      base_ctx
      |> Map.merge(ctx_overrides)
      |> Map.put(:current_func, current_func)
      |> Map.put(:arg_buf, List.to_tuple(args))

    prev_fast_ctx = snapshot_fast_ctx()

    Heap.put_ctx(next_ctx)
    put_fast_ctx(next_ctx)

    try do
      callback.()
    after
      if prev_ctx, do: Heap.put_ctx(prev_ctx), else: Process.delete(:qb_ctx)
      restore_fast_ctx(prev_fast_ctx)
    end
  end

  defp snapshot_fast_ctx do
    Map.new(@fast_ctx_keys, fn key -> {key, Process.get(key, @missing)} end)
  end

  defp put_fast_ctx(ctx) do
    current_func = Map.get(ctx, :current_func, :undefined)
    home_object = current_home_object(current_func)

    Process.put(:qb_ctx_atoms, Map.get(ctx, :atoms, {}))
    Process.put(:qb_ctx_globals, Map.get(ctx, :globals, %{}))
    Process.put(:qb_current_func, current_func)
    Process.put(:qb_arg_buf, Map.get(ctx, :arg_buf, {}))
    Process.put(:qb_this, Map.get(ctx, :this, :undefined))
    Process.put(:qb_new_target, Map.get(ctx, :new_target, :undefined))
    Process.put(:qb_home_object_current, home_object)
    Process.put(:qb_super_current, current_super(home_object))
  end

  defp current_home_object(current_func) do
    Process.get({:qb_home_object, home_object_key(current_func)}, :undefined)
  end

  defp current_super(:undefined), do: :undefined
  defp current_super(home_object), do: Semantics.get_super(home_object)

  defp home_object_key({:closure, _, %Bytecode.Function{byte_code: byte_code}}), do: byte_code
  defp home_object_key(%Bytecode.Function{byte_code: byte_code}), do: byte_code
  defp home_object_key(_), do: nil

  defp restore_fast_ctx(snapshot) do
    Enum.each(snapshot, fn
      {key, @missing} -> Process.delete(key)
      {key, value} -> Process.put(key, value)
    end)
  end

  defp normalize_args(args, arg_count) do
    args
    |> Enum.take(arg_count)
    |> then(fn args -> args ++ List.duplicate(:undefined, arg_count - length(args)) end)
  end
end
