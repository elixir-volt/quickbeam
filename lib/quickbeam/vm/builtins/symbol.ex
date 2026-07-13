defmodule QuickBEAM.VM.Builtins.Symbol do
  @moduledoc "Defines the well-known symbols exposed by the core VM profile."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Symbol

  builtin "Symbol", kind: :namespace do
    constant "iterator", Symbol.iterator()
  end
end
