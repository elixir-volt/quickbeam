defmodule QuickBEAM.VM.Builtin.Error do
  @moduledoc "Defines the declarative JavaScript Error constructor and prototype."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtin.Error.Support

  builtin "Error",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function"] do
    prototype extends: "Object", error_type: "Error" do
      prototype_value "name", "Error", writable: true, configurable: true
      prototype_value "message", "", writable: true, configurable: true
      method :to_string_method, js: "toString", length: 0
    end
  end

  @doc "Constructs an Error value."
  def construct(%Call{} = call), do: Support.construct("Error", call)

  @doc "Formats an Error value."
  def to_string_method(%Call{} = call), do: Support.to_string(call)
end
