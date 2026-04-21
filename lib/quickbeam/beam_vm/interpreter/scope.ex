defmodule QuickBEAM.BeamVM.Interpreter.Scope do
  @moduledoc false

  alias QuickBEAM.BeamVM.{GlobalEnv, Names}
  alias QuickBEAM.BeamVM.Interpreter.Context

  @compile {:inline,
            resolve_const: 2, resolve_atom: 2, resolve_global: 2, set_global: 3, get_arg_value: 2}

  defdelegate resolve_const(cpool, idx), to: Names
  defdelegate resolve_atom(atoms_or_ctx, idx), to: Names

  def resolve_global(%Context{} = ctx, atom_idx), do: GlobalEnv.fetch(ctx, atom_idx)
  def set_global(%Context{} = ctx, atom_idx, val), do: GlobalEnv.put(ctx, atom_idx, val)

  def get_arg_value(%Context{arg_buf: arg_buf}, idx) do
    if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
  end
end
