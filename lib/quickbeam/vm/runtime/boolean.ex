defmodule QuickBEAM.VM.Runtime.Boolean do
  @moduledoc false

  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Runtime

  proto "toString" do
    Atom.to_string(this)
  end

  proto "valueOf" do
    this
  end

  def constructor,
    do: fn args, _this -> Runtime.truthy?(List.first(args, false)) end
end
