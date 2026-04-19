defmodule QuickBEAM.BeamVM.Runtime.Boolean do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Runtime

  proto "toString" do
    Atom.to_string(this)
  end

  proto "valueOf" do
    this
  end

  def constructor,
    do: fn args, _this -> Runtime.truthy?(List.first(args, false)) end
end
