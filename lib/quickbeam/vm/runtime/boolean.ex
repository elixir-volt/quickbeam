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

  def constructor do
    fn
      args, {:obj, _} = this ->
        val = Runtime.truthy?(List.first(args, false))
        QuickBEAM.VM.ObjectModel.Put.put(this, "__wrapped_boolean__", val)
        this

      args, _ ->
        Runtime.truthy?(List.first(args, false))
    end
  end
end
