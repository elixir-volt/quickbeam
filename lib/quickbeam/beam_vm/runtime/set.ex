defmodule QuickBEAM.BeamVM.Runtime.Set do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime.MapSet

  def constructor, do: MapSet.set_constructor()
  def proto_property(key), do: MapSet.set_proto(key)
end
