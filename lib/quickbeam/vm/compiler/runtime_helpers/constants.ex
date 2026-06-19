defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Constants do
  @moduledoc "Compiler-private materialization of atom-table values, constants, and literal runtime forms."

  alias QuickBEAM.VM.{Heap, Names}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.Private

  @doc "Resolves an atom-table entry to its runtime value."
  def push_atom_value(ctx, atom_idx), do: Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx)
  def push_atom_value(atom_idx), do: Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)

  def private_symbol(_ctx, name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(ctx, atom_idx),
    do: Private.private_symbol(Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx))

  def private_symbol(name) when is_binary(name), do: Private.private_symbol(name)

  def private_symbol(atom_idx),
    do: Private.private_symbol(Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def materialize_constant(_ctx, {:template_object, elems, raw}) do
    elems = template_elements(elems)
    raw_elements = template_raw_elements(raw, elems)

    raw_ref = make_ref()
    Heap.put_obj(raw_ref, template_object_map(raw_elements))

    ref = make_ref()
    Heap.put_obj(ref, Map.put(template_object_map(elems), "raw", {:obj, raw_ref}))
    {:obj, ref}
  end

  def materialize_constant(_ctx, value), do: value

  def regexp_literal(_ctx \\ nil, pattern, flags), do: {:regexp, pattern, flags, make_ref()}

  defp template_elements({:array, elems}) when is_list(elems), do: elems
  defp template_elements(elems) when is_list(elems), do: elems
  defp template_elements(value), do: [value]

  defp template_raw_elements(:undefined, elems), do: elems
  defp template_raw_elements({:template_object, raw, _}, _elems), do: template_elements(raw)
  defp template_raw_elements(raw, _elems), do: template_elements(raw)

  defp template_object_map(elems) do
    elems
    |> Enum.with_index()
    |> Enum.reduce(%{"length" => length(elems)}, fn {value, idx}, acc ->
      Map.put(acc, Integer.to_string(idx), value)
    end)
  end
end
