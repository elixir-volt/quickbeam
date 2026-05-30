defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Classes do
  @moduledoc "Class definition, method installation, and private-brand helpers for BEAM-compiled JavaScript."

  alias QuickBEAM.VM.Names
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Class, Functions, Methods, Private}

  def define_class(ctx, ctor, parent_ctor, atom_idx) do
    Class.define_class(
      ctor_closure(ctor),
      parent_ctor,
      Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx)
    )
  end

  def define_class(ctor, parent_ctor, atom_idx) do
    Class.define_class(
      ctor_closure(ctor),
      parent_ctor,
      Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)
    )
  end

  def define_class_computed(_ctx, ctor, parent_ctor, computed_name) do
    Class.define_class(ctor_closure(ctor), parent_ctor, Functions.function_name(computed_name))
  end

  @doc "Defines a method, getter, or setter from compiled code."
  def define_method(_ctx, target, method, name, flags) when is_binary(name),
    do: Methods.define_method(target, method, name, flags)

  def define_method(_ctx, target, method, {:tagged_int, _} = atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        QuickBEAM.VM.ObjectModel.PropertyKey.normalize(atom_idx),
        flags
      )

  def define_method(ctx, target, method, atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx),
        flags
      )

  def define_method(target, method, name, flags) when is_binary(name),
    do: Methods.define_method(target, method, name, flags)

  def define_method(target, method, {:tagged_int, _} = atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        QuickBEAM.VM.ObjectModel.PropertyKey.normalize(atom_idx),
        flags
      )

  def define_method(target, method, atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        Names.resolve_atom(InvokeContext.current_atoms(), atom_idx),
        flags
      )

  @doc "Defines a computed-name method, getter, or setter from compiled code."
  def define_method_computed(_ctx \\ nil, target, method, field_name, flags),
    do: Methods.define_method_computed(target, method, field_name, flags)

  def add_brand(_ctx \\ nil, target, brand), do: Private.add_brand(target, brand)

  def check_brand(_ctx, object, brand) do
    case Private.ensure_brand(object, brand) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  defp ctor_closure(%QuickBEAM.VM.Function{} = fun), do: {:closure, %{}, fun}
  defp ctor_closure(other), do: other
end
