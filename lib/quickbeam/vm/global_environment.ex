defmodule QuickBEAM.VM.GlobalEnvironment do
  @moduledoc """
  Global binding support for the BEAM VM.

  Spec relation:
  - ECMA-262 §9.1.1.4 Global Environment Records
  - ECMA-262 §9.4 Execution Contexts

  Implementation note:
  QuickJS bytecode resolves much of lexical binding behavior before this layer.
  This module models the observable global binding behavior needed by bytecode
  execution, not the full Environment Record hierarchy.
  """

  alias QuickBEAM.VM.Execution.GlobalBindingState
  alias QuickBEAM.VM.{Heap, JSThrow, Names, Runtime, RuntimeState}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.ObjectModel.InternalMethods
  alias QuickBEAM.VM.Semantics.Values

  @doc "Returns the active JavaScript global environment."
  def current do
    case RuntimeState.current() do
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
  def fetch(%Context{} = ctx, atom_idx),
    do: fetch(Map.merge(ctx.globals, Heap.get_persistent_globals() || %{}), atom_idx, ctx.atoms)

  def fetch(globals, atom_idx) when is_map(globals),
    do: fetch(globals, atom_idx, Heap.get_atoms())

  def fetch(atom_idx), do: fetch(current(), atom_idx, Heap.get_atoms())

  def get(%Context{} = ctx, atom_idx, default),
    do:
      get(
        Map.merge(ctx.globals, Heap.get_persistent_globals() || %{}),
        atom_idx,
        default,
        ctx.atoms
      )

  def get(globals, atom_idx, default) when is_map(globals),
    do: get(globals, atom_idx, default, Heap.get_atoms())

  def get(atom_idx, default), do: get(current(), atom_idx, default, Heap.get_atoms())

  @doc "Writes a global binding into a context and optionally persists it."
  def put(%Context{} = ctx, atom_idx, val, opts \\ []) do
    name = Names.resolve_atom(ctx, atom_idx)
    init? = Keyword.get(opts, :init, false)
    strict? = Keyword.get(opts, :strict, false)
    current = current_binding(ctx, name)

    if current == :not_found and strict? and not init? do
      JSThrow.reference_error!("#{name} is not defined")
    end

    if current == :__tdz__ and not init? do
      JSThrow.reference_error!("Cannot access variable before initialization")
    end

    if GlobalBindingState.const?(name) and not init? do
      JSThrow.type_error!("Assignment to constant variable")
    end

    if readonly_global_value?(name) and not init? do
      if strict?, do: JSThrow.type_error!("Assignment to constant variable")
      throw({:global_readonly_noop, ctx})
    end

    if current == :not_found and not init? and observable_global_property?(ctx, name) do
      validate_global_set_result!(
        strict?,
        name,
        InternalMethods.set(Map.get(ctx.globals, "globalThis"), name, val)
      )

      globals =
        ctx.globals |> Map.merge(Heap.get_persistent_globals() || %{}) |> Map.put(name, val)

      if Keyword.get(opts, :persist, true) do
        Heap.put_persistent_globals(globals)
        Heap.put_base_globals(globals)
      end

      RuntimeState.refresh_globals(%{ctx | globals: globals})
    else
      globals =
        ctx.globals |> Map.merge(Heap.get_persistent_globals() || %{}) |> Map.put(name, val)

      if Keyword.get(opts, :sync_global_this, true) and not lexical_global?(name) do
        sync_global_this_property(globals, name, val)
      end

      if Keyword.get(opts, :persist, true) do
        Heap.put_persistent_globals(globals)
        Heap.put_base_globals(globals)
      end

      %{ctx | globals: globals} |> Context.mark_dirty()
    end
  catch
    {:global_readonly_noop, ctx} -> ctx
  end

  @doc "Defines a hoisted `var` binding in the active global environment."
  def define_var(%Context{} = ctx, atom_idx, flags \\ 0) do
    name = Names.resolve_atom(ctx, atom_idx)
    lexical? = lexical_global_flags?(flags)
    initial = if lexical?, do: :__tdz__, else: :undefined
    Heap.put_var(name, initial)
    GlobalBindingState.mark_const(name, const_global_flags?(flags))
    GlobalBindingState.mark_lexical(name, lexical?)
    globals = Map.put_new(ctx.globals, name, initial)

    unless lexical? do
      sync_global_this_property(globals, name, Map.get(globals, name))
    end

    Heap.put_persistent_globals(globals)
    Context.mark_dirty(%{ctx | globals: globals})
  end

  @doc "Clears temporary `var` tracking after declaration checks."
  def check_define_var(%Context{} = ctx, atom_idx) do
    Heap.delete_var(Names.resolve_atom(ctx, atom_idx))
    Context.mark_dirty(ctx)
  end

  defp current_binding(ctx, name) do
    persistent = Heap.get_persistent_globals() || %{}

    cond do
      Map.has_key?(persistent, name) -> Map.get(persistent, name)
      Map.has_key?(ctx.globals, name) -> Map.get(ctx.globals, name)
      true -> :not_found
    end
  end

  defp lexical_global_flags?(flags) when is_integer(flags), do: Bitwise.band(flags, 0x80) == 0x80
  defp lexical_global_flags?(_flags), do: false

  defp const_global_flags?(flags) when is_integer(flags), do: Bitwise.band(flags, 0x82) == 0x80
  defp const_global_flags?(_flags), do: false

  def lexical_global?(name), do: GlobalBindingState.lexical?(name)

  defp readonly_global_value?(name), do: name in ["NaN", "Infinity", "undefined"]

  defp observable_global_property?(ctx, name) do
    case Map.get(ctx.globals, "globalThis") do
      {:obj, _} = global_this -> InternalMethods.has_property(global_this, name)
      _ -> false
    end
  end

  defp validate_global_set_result!(strict?, name, result) do
    if Values.truthy?(result) or not strict? do
      :ok
    else
      JSThrow.type_error!("Cannot assign to #{name}")
    end
  end

  defp sync_global_this_property(_globals, "globalThis", _val), do: :ok

  defp sync_global_this_property(globals, name, val) do
    case Map.get(globals, "globalThis") do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> Heap.put_obj_key(ref, map, name, val)
          _ -> :ok
        end

      _ ->
        :ok
    end
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
