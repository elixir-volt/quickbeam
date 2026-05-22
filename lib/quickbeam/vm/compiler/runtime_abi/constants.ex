defmodule QuickBEAM.VM.Compiler.RuntimeABI.Constants do
  @moduledoc false

  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Constants, as: RuntimeConstants
  alias QuickBEAM.VM.ObjectModel.PropertyKey

  def push_atom_value(ctx, atom_idx), do: RuntimeConstants.push_atom_value(ctx, atom_idx)

  def private_symbol(ctx, name_or_atom_idx),
    do: RuntimeConstants.private_symbol(ctx, name_or_atom_idx)

  def materialize_constant(ctx, value), do: RuntimeConstants.materialize_constant(ctx, value)

  def regexp_literal(ctx, pattern, flags),
    do: RuntimeConstants.regexp_literal(ctx, pattern, flags)

  def to_property_key_raw(_ctx, value), do: PropertyKey.to_property_key(value)
end
