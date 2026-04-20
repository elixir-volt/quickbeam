defmodule QuickBEAM.BeamVM.Compiler.Runner do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap, Runtime}
  alias QuickBEAM.BeamVM.Compiler
  alias QuickBEAM.BeamVM.Interpreter.Context

  def invoke(%Bytecode.Function{closure_vars: []} = fun, args) do
    key = {fun.byte_code, fun.arg_count}
    args = normalize_args(args, fun.arg_count)

    if atoms = Process.get({:qb_fn_atoms, fun.byte_code}) do
      Heap.put_atoms(atoms)
    end

    with_compiled_ctx(fun, args, fn ->
      case Heap.get_compiled(key) do
        {:compiled, {mod, name}} -> {:ok, apply(mod, name, args)}
        :unsupported -> :error
        nil -> compile_and_invoke(fun, args, key)
      end
    end)
  end

  def invoke(_, _), do: :error

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

  defp with_compiled_ctx(fun, args, callback) do
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

    Heap.put_ctx(%{base_ctx | current_func: fun, arg_buf: List.to_tuple(args)})

    try do
      callback.()
    after
      if prev_ctx, do: Heap.put_ctx(prev_ctx), else: Process.delete(:qb_ctx)
    end
  end

  defp normalize_args(args, arg_count) do
    args
    |> Enum.take(arg_count)
    |> then(fn args -> args ++ List.duplicate(:undefined, arg_count - length(args)) end)
  end
end
