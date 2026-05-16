defmodule QuickBEAM.VM.Compiler.RuntimeABI do
  @moduledoc """
  Stable runtime ABI called from lowered BEAM compiler output.

  `RuntimeHelpers` remains the implementation façade. This module names the
  subset of helpers that generated code should treat as ABI: operations whose
  calling convention is part of compiler lowering rather than an implementation
  detail of a particular helper module.
  """

  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  def to_object(value), do: RuntimeHelpers.to_object(value)
  def to_object(_ctx, value), do: RuntimeHelpers.to_object(value)

  def to_property_key(value), do: RuntimeHelpers.to_property_key(value)
  def to_property_key(ctx, value), do: RuntimeHelpers.to_property_key(ctx, value)

  def to_property_key_for_access(ctx, receiver, key),
    do: RuntimeHelpers.to_property_key_for_access(ctx, receiver, key)

  def copy_data_properties(ctx, target, source, exclude),
    do: RuntimeHelpers.copy_data_properties(ctx, target, source, exclude)

  def get_array_el2(ctx, obj, index), do: RuntimeHelpers.get_array_el2(ctx, obj, index)

  def put_array_el(ctx, obj, index, value),
    do: RuntimeHelpers.put_array_el(ctx, obj, index, value)

  def get_field(_ctx, obj, key), do: RuntimeHelpers.get_field(obj, key)

  def put_field(ctx, obj, key, value), do: RuntimeHelpers.put_field(ctx, obj, key, value)
end
