defmodule QuickBEAM.BeamVM.Compiler.Runner do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap}
  alias QuickBEAM.BeamVM.Compiler

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
end
