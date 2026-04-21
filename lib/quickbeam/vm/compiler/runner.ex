defmodule QuickBEAM.VM.Compiler.Runner do
  @moduledoc false

  alias QuickBEAM.VM.{Bytecode, GlobalEnv, Heap}
  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  def invoke(%Bytecode.Function{} = fun, args), do: invoke(fun, args, nil)
  def invoke({:closure, _, %Bytecode.Function{}} = closure, args), do: invoke(closure, args, nil)
  def invoke(_, _), do: :error

  def invoke(%Bytecode.Function{} = fun, args, base_ctx),
    do: invoke_target(fun, fun, args, %{}, base_ctx)

  def invoke({:closure, _, %Bytecode.Function{} = fun} = closure, args, base_ctx),
    do: invoke_target(closure, fun, args, %{}, base_ctx)

  def invoke(_, _, _), do: :error

  def invoke_with_receiver(%Bytecode.Function{} = fun, args, this_obj),
    do: invoke_with_receiver(fun, args, this_obj, nil)

  def invoke_with_receiver({:closure, _, %Bytecode.Function{}} = closure, args, this_obj),
    do: invoke_with_receiver(closure, args, this_obj, nil)

  def invoke_with_receiver(_, _, _), do: :error

  def invoke_with_receiver(%Bytecode.Function{} = fun, args, this_obj, base_ctx),
    do: invoke_target(fun, fun, args, %{this: this_obj}, base_ctx)

  def invoke_with_receiver(
        {:closure, _, %Bytecode.Function{} = fun} = closure,
        args,
        this_obj,
        base_ctx
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj}, base_ctx)

  def invoke_with_receiver(_, _, _, _), do: :error

  def invoke_constructor(%Bytecode.Function{} = fun, args, this_obj, new_target),
    do: invoke_constructor(fun, args, this_obj, new_target, nil)

  def invoke_constructor(
        {:closure, _, %Bytecode.Function{}} = closure,
        args,
        this_obj,
        new_target
      ),
      do: invoke_constructor(closure, args, this_obj, new_target, nil)

  def invoke_constructor(_, _, _, _), do: :error

  def invoke_constructor(%Bytecode.Function{} = fun, args, this_obj, new_target, base_ctx),
    do: invoke_target(fun, fun, args, %{this: this_obj, new_target: new_target}, base_ctx)

  def invoke_constructor(
        {:closure, _, %Bytecode.Function{} = fun} = closure,
        args,
        this_obj,
        new_target,
        base_ctx
      ),
      do: invoke_target(closure, fun, args, %{this: this_obj, new_target: new_target}, base_ctx)

  def invoke_constructor(_, _, _, _, _), do: :error

  defp invoke_target(current_func, %Bytecode.Function{} = fun, args, ctx_overrides, base_ctx) do
    key = {fun.byte_code, fun.arg_count}
    args = normalize_args(args, fun.arg_count)
    ctx = invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun)

    case Heap.get_compiled(key) do
      {:compiled, {mod, name}} -> {:ok, apply_compiled({mod, name}, ctx, args)}
      :unsupported -> :error
      nil -> compile_and_invoke(fun, ctx, args, key)
    end
  end

  defp compile_and_invoke(fun, ctx, args, key) do
    case Compiler.compile(fun) do
      {:ok, compiled} ->
        Heap.put_compiled(key, {:compiled, compiled})
        {:ok, apply_compiled(compiled, ctx, args)}

      {:error, _} ->
        Heap.put_compiled(key, :unsupported)
        :error
    end
  end

  defp apply_compiled({mod, name}, ctx, args), do: apply(mod, name, [ctx | args])

  defp invocation_ctx(base_ctx, current_func, args, ctx_overrides, fun) do
    atoms = Process.get({:qb_fn_atoms, fun.byte_code}, current_atoms(base_ctx))

    base_ctx
    |> base_ctx()
    |> Map.put(:atoms, atoms)
    |> Map.merge(ctx_overrides)
    |> Map.put(:current_func, current_func)
    |> Map.put(:arg_buf, List.to_tuple(args))
    |> Map.put(:trace_enabled, Map.get(base_ctx || %{}, :trace_enabled, false))
    |> InvokeContext.attach_method_state()
    |> Context.mark_dirty()
  end

  defp base_ctx(%Context{} = ctx), do: ensure_globals(ctx)

  defp base_ctx(nil) do
    %Context{atoms: Heap.get_atoms(), globals: base_globals(), trace_enabled: false}
  end

  defp base_ctx(map) when is_map(map) do
    map
    |> then(&struct(Context, Map.merge(Map.from_struct(%Context{}), &1)))
    |> ensure_globals()
  end

  defp ensure_globals(%Context{globals: globals} = ctx) when globals == %{},
    do: %{ctx | globals: base_globals()}

  defp ensure_globals(%Context{} = ctx), do: ctx

  defp base_globals, do: GlobalEnv.base_globals()

  defp current_atoms(%Context{} = ctx), do: ctx.atoms
  defp current_atoms(map) when is_map(map), do: Map.get(map, :atoms, Heap.get_atoms())
  defp current_atoms(_), do: Heap.get_atoms()

  defp normalize_args(_args, 0), do: []
  defp normalize_args([a0 | _], 1), do: [a0]
  defp normalize_args([], 1), do: [:undefined]
  defp normalize_args([a0, a1 | _], 2), do: [a0, a1]
  defp normalize_args([a0], 2), do: [a0, :undefined]
  defp normalize_args([], 2), do: [:undefined, :undefined]
  defp normalize_args([a0, a1, a2 | _], 3), do: [a0, a1, a2]
  defp normalize_args([a0, a1], 3), do: [a0, a1, :undefined]
  defp normalize_args([a0], 3), do: [a0, :undefined, :undefined]
  defp normalize_args([], 3), do: [:undefined, :undefined, :undefined]

  defp normalize_args(args, arg_count) do
    args
    |> Enum.take(arg_count)
    |> then(fn args -> args ++ List.duplicate(:undefined, arg_count - length(args)) end)
  end
end
