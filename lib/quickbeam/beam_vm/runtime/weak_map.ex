defmodule QuickBEAM.BeamVM.Runtime.WeakMap do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime.MapSet

  def constructor, do: MapSet.weak_map_constructor()
end
