defmodule QuickBEAM.BeamVM.Runtime.Map do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime.MapSet

  def constructor, do: MapSet.map_constructor()
  def proto_property(key), do: MapSet.map_proto(key)
end
