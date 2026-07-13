defmodule QuickBEAM.VM.Builtin.Registry do
  @moduledoc """
  Defines the explicit deterministic builtin registry for each VM profile.

  Modules are listed deliberately; runtime application-module discovery is not
  used because it makes installation dependent on code-loading order.
  """

  @core [
    QuickBEAM.VM.Builtins.Object,
    QuickBEAM.VM.Builtins.Function,
    QuickBEAM.VM.Builtins.Math,
    QuickBEAM.VM.Builtins.Array,
    QuickBEAM.VM.Builtins.String,
    QuickBEAM.VM.Builtins.Number,
    QuickBEAM.VM.Builtins.Boolean,
    QuickBEAM.VM.Builtins.Error,
    QuickBEAM.VM.Builtins.EvalError,
    QuickBEAM.VM.Builtins.RangeError,
    QuickBEAM.VM.Builtins.ReferenceError,
    QuickBEAM.VM.Builtins.SyntaxError,
    QuickBEAM.VM.Builtins.TypeError,
    QuickBEAM.VM.Builtins.URIError,
    QuickBEAM.VM.Builtins.Symbol,
    QuickBEAM.VM.Builtins.Set,
    QuickBEAM.VM.Builtins.Promise
  ]

  @doc "Returns builtin modules installed for a profile in dependency order."
  @spec modules(atom()) :: [module()]
  def modules(:core), do: @core
  def modules(_profile), do: []
end
