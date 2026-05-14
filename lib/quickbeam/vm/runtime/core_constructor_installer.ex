defmodule QuickBEAM.VM.Runtime.CoreConstructorInstaller do
  @moduledoc "Installs small core constructors that do not need dedicated installer modules."

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Boolean
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.PromiseBuiltins
  alias QuickBEAM.VM.Runtime.Symbol

  @doc "Returns global bindings for small core constructors."
  def bindings do
    %{
      "BigInt" =>
        ConstructorRegistry.register("BigInt", &Constructors.bigint/2, auto_proto: true),
      "Boolean" =>
        ConstructorRegistry.register("Boolean", Boolean.constructor(),
          module: Boolean,
          auto_proto: true
        ),
      "Promise" =>
        ConstructorRegistry.register("Promise", PromiseBuiltins.constructor(),
          module: PromiseBuiltins,
          prototype: PromiseBuiltins.prototype()
        ),
      "Symbol" =>
        ConstructorRegistry.register("Symbol", Symbol.constructor(),
          module: Symbol,
          auto_proto: true
        ),
      "DataView" => ConstructorRegistry.register("DataView", fn _, _ -> Runtime.new_object() end)
    }
  end
end
