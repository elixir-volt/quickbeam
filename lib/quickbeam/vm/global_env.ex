defmodule QuickBEAM.VM.GlobalEnv do
  @moduledoc "Global variable environment: resolves JS globals from the persistent heap and runtime bindings."

  alias QuickBEAM.VM.{Heap, Names, Runtime}
  alias QuickBEAM.VM.Interpreter.Context

  @doc "Returns the active JavaScript global environment."
  def current do
    case Heap.get_ctx() do
      %Context{globals: globals} when globals != %{} -> globals
      %Context{} -> base_globals()
      _ -> base_globals()
    end
  end

  @doc "Returns cached builtin and persistent global bindings."
  def base_globals do
    case Heap.get_base_globals() do
      nil ->
        builtins = Runtime.global_bindings()
        persistent = Heap.get_persistent_globals() || %{}
        globals = Map.merge(builtins, Map.drop(persistent, Map.keys(builtins)))
        Heap.put_base_globals(globals)
        globals

      globals ->
        globals
    end
  end

  @doc "Fetches a global binding by name or atom-table index."
  def fetch(%Context{} = ctx, atom_idx), do: fetch(ctx.globals, atom_idx, ctx.atoms)

  def fetch(globals, atom_idx) when is_map(globals),
    do: fetch(globals, atom_idx, Heap.get_atoms())

  def fetch(atom_idx), do: fetch(current(), atom_idx, Heap.get_atoms())

  def get(%Context{} = ctx, atom_idx, default),
    do: get(ctx.globals, atom_idx, default, ctx.atoms)

  def get(globals, atom_idx, default) when is_map(globals),
    do: get(globals, atom_idx, default, Heap.get_atoms())

  def get(atom_idx, default), do: get(current(), atom_idx, default, Heap.get_atoms())

  @doc "Writes a global binding into a context and optionally persists it."
  def put(%Context{} = ctx, atom_idx, val, opts \\ []) do
    name = Names.resolve_atom(ctx, atom_idx)
    globals = Map.put(ctx.globals, name, val)

    if Keyword.get(opts, :persist, true) do
      Heap.put_persistent_globals(globals)
      Heap.put_base_globals(globals)
    end

    %{ctx | globals: globals} |> Context.mark_dirty()
  end

  @doc "Defines a hoisted `var` binding in the active global environment."
  def define_var(%Context{} = ctx, atom_idx) do
    name = Names.resolve_atom(ctx, atom_idx)
    Heap.put_var(name, :undefined)
    globals = Map.put_new(ctx.globals, name, :undefined)
    Heap.put_persistent_globals(globals)
    Context.mark_dirty(%{ctx | globals: globals})
  end

  @doc "Clears temporary `var` tracking after declaration checks."
  def check_define_var(%Context{} = ctx, atom_idx) do
    Heap.delete_var(Names.resolve_atom(ctx, atom_idx))
    Context.mark_dirty(ctx)
  end

  def refresh(%Context{} = ctx) do
    globals = Map.merge(ctx.globals, Heap.get_persistent_globals() || %{})
    Heap.put_base_globals(globals)
    %{ctx | globals: globals} |> Context.mark_dirty()
  end

  @doc "Resolves a name from the current atom table."
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
