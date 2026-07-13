defmodule QuickBEAM.VM.Builtins.Symbol do
  @moduledoc "Defines the well-known symbols exposed by the core VM profile."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Symbol, Value}

  builtin "Symbol", kind: :function, length: 0 do
    constant "iterator", Symbol.iterator()
  end

  @doc "Creates a fresh owner-local Symbol value."
  def call(%Call{arguments: arguments, execution: execution}) do
    id = execution.next_symbol_id

    description =
      case arguments do
        [value | _] when value != :undefined -> Value.to_string_value(value)
        _arguments -> ""
      end

    symbol = %Symbol{id: {:local, id}, description: description}
    {:ok, symbol, %{execution | next_symbol_id: id + 1}}
  end
end
