defmodule QuickBEAM.BeamVM.Runtime.WeakSet do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime.MapSet

  def constructor, do: MapSet.weak_set_constructor()
end
