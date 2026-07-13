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
    QuickBEAM.VM.Builtins.Uint8Array,
    QuickBEAM.VM.Builtins.Map,
    QuickBEAM.VM.Builtins.WeakMap,
    QuickBEAM.VM.Builtins.Set,
    QuickBEAM.VM.Builtins.WeakSet,
    QuickBEAM.VM.Builtins.Promise
  ]

  @ssr @core ++ [QuickBEAM.VM.Builtins.Console]

  @doc "Returns builtin modules installed for a profile in dependency order."
  @spec modules(:core | :ssr) :: [module()]
  def modules(:core), do: @core
  def modules(:ssr), do: @ssr
end
