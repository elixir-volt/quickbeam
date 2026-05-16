defmodule QuickBEAM.VM.Compiler.Effects do
  @moduledoc "Semantic effects for VM operations that can invalidate compiler assumptions."

  @effects %{
    to_property_key: %{calls_js?: true, invalidates_shape_aliases?: true},
    copy_data_properties: %{calls_js?: true, invalidates_shape_aliases?: true},
    create_data_property: %{calls_js?: false, invalidates_shape_aliases?: true}
  }

  def effect(operation), do: Map.get(@effects, operation, %{})

  def calls_js?(operation), do: Map.get(effect(operation), :calls_js?, false)

  def invalidates_shape_aliases?(operation),
    do: Map.get(effect(operation), :invalidates_shape_aliases?, false)
end
