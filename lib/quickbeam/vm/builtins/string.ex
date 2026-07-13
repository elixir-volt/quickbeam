defmodule QuickBEAM.VM.Builtins.String do
  @moduledoc "Defines declarative additions to the core `String` constructor."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Value

  builtin "String", kind: :extension do
    static("fromCharCode", :from_char_code, length: 1)
  end

  @doc "Implements `String.fromCharCode`."
  def from_char_code(%Call{arguments: values, execution: execution}),
    do: {:ok, Value.string_from_char_codes(values), execution}
end
