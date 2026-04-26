defmodule QuickBEAM.VM.Runtime.BuiltinObject do
  @moduledoc "Contract for modules that expose JS builtin constructor/prototype/static entries."

  @callback constructor() :: term()
  @callback constructor(list(), term()) :: term()
  @callback object() :: term()
  @callback proto_property(term()) :: term()
  @callback static_property(term()) :: term()

  @optional_callbacks constructor: 0,
                      constructor: 2,
                      object: 0,
                      proto_property: 1,
                      static_property: 1
end
