defmodule QuickBEAM.VM.Builtin.Error.Subclass do
  @moduledoc "Generates one declarative native Error subclass builtin."

  @doc "Defines one declarative native Error subclass."
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)

    quote do
      use QuickBEAM.VM.Builtin

      alias QuickBEAM.VM.Builtin.Call
      alias QuickBEAM.VM.Builtin.Error.Support

      @error_name unquote(name)

      builtin unquote(name),
        kind: :constructor,
        constructor: :construct,
        length: 1,
        depends_on: ["Error", "Function"] do
        prototype extends: "Error", error_type: unquote(name) do
          prototype_value "name", unquote(name), writable: true, configurable: true
          prototype_value "message", "", writable: true, configurable: true
        end
      end

      @doc "Constructs this native Error subclass."
      def construct(%Call{} = call), do: Support.construct(@error_name, call)
    end
  end
end
