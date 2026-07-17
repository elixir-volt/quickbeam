defmodule QuickBEAM.VM.Builtin.Symbol do
  @moduledoc "Defines the well-known symbols exposed by the core VM profile."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Symbol
  alias QuickBEAM.VM.Runtime.Value

  builtin "Symbol", kind: :function, length: 0, depends_on: ["Object", "Function"] do
    static :for_symbol, js: "for", length: 1
    constant "iterator", Symbol.iterator()
  end

  @doc "Returns the evaluation-stable global symbol for a string key."
  def for_symbol(%Call{arguments: arguments, execution: execution}) do
    key = arguments |> List.first(:undefined) |> Value.to_string_value()
    {:ok, %Symbol{id: {:global, key}, description: key}, execution}
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
