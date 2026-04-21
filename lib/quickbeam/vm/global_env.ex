defmodule QuickBEAM.VM.GlobalEnv do
  @moduledoc false

  alias QuickBEAM.VM.{Heap, Names, Runtime}
  alias QuickBEAM.VM.Interpreter.Context

  def current do
    case Heap.get_ctx() do
      %Context{globals: globals} when globals != %{} -> globals
      %Context{} -> base_globals()
      _ -> base_globals()
    end
  end

  def base_globals do
    builtins = Runtime.global_bindings()
    persistent = Heap.get_persistent_globals() || %{}
    Map.merge(builtins, Map.drop(persistent, Map.keys(builtins)))
  end

  def fetch(%Context{} = ctx, atom_idx), do: fetch(ctx.globals, atom_idx, ctx.atoms)

  def fetch(globals, atom_idx) when is_map(globals),
    do: fetch(globals, atom_idx, Heap.get_atoms())

  def fetch(atom_idx), do: fetch(current(), atom_idx, Heap.get_atoms())

  def get(%Context{} = ctx, atom_idx, default),
    do: get(ctx.globals, atom_idx, default, ctx.atoms)

  def get(globals, atom_idx, default) when is_map(globals),
    do: get(globals, atom_idx, default, Heap.get_atoms())

  def get(atom_idx, default), do: get(current(), atom_idx, default, Heap.get_atoms())

  def put(%Context{} = ctx, atom_idx, val, opts \\ []) do
    name = Names.resolve_atom(ctx, atom_idx)
    globals = Map.put(ctx.globals, name, val)

    if Keyword.get(opts, :persist, true) do
      Heap.put_persistent_globals(globals)
    end

    %{ctx | globals: globals} |> Context.mark_dirty()
  end

  def define_var(%Context{} = ctx, atom_idx) do
    Heap.put_var(Names.resolve_atom(ctx, atom_idx), :undefined)
    Context.mark_dirty(ctx)
  end

  def check_define_var(%Context{} = ctx, atom_idx) do
    Heap.delete_var(Names.resolve_atom(ctx, atom_idx))
    Context.mark_dirty(ctx)
  end

  def refresh(%Context{} = ctx) do
    persistent = Heap.get_persistent_globals() || %{}
    %{ctx | globals: Map.merge(ctx.globals, persistent)} |> Context.mark_dirty()
  end

  def current_name(atom_idx), do: Names.resolve_atom(Heap.get_atoms(), atom_idx)

  defp fetch(globals, atom_idx, atoms) do
    name = resolve_name(atom_idx, atoms)

    case Map.fetch(globals, name) do
      {:ok, val} -> {:found, val}
      :error -> :not_found
    end
  end

  defp get(globals, atom_idx, default, atoms) do
    name = resolve_name(atom_idx, atoms)
    Map.get(globals, name, default)
  end

  defp resolve_name(name, _atoms) when is_binary(name), do: name
  defp resolve_name(name, atoms), do: Names.resolve_atom(atoms, name)
end
