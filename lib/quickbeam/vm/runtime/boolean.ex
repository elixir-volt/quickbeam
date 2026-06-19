defmodule QuickBEAM.VM.Runtime.Boolean do
  @moduledoc "JavaScript `Boolean` constructor and prototype builtins."

  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.ObjectModel.InternalMethods
  alias QuickBEAM.VM.Runtime

  @ecma "20.3"
  defintrinsic "Boolean" do
    constructor length: 1, phase: :fundamental do
      case {args, this} do
        {args, {:obj, _} = this} ->
          val = args |> arg(0, false) |> Runtime.truthy?()
          InternalMethods.set(this, slot_key(:BooleanData), val)
          this

        {args, _} ->
          args |> arg(0, false) |> Runtime.truthy?()
      end
    end

    prototype extends: :object do
      slot(:BooleanData, false)

      @ecma "20.3.3.2"
      method "toString", receiver: :boolean do
        Atom.to_string(this)
      end

      @ecma "20.3.3.3"
      method "valueOf", receiver: :boolean do
        this
      end
    end
  end
end
