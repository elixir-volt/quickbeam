defmodule QuickBEAM.VM.Runtime.Callable do
  @moduledoc """
  Classifies represented JavaScript callable values without planning or
  executing an invocation.
  """

  alias QuickBEAM.VM.Builtin.Runtime, as: BuiltinRuntime
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Value

  @callable_tags [
    :builtin,
    :declared_builtin,
    :bound_function,
    :host_function,
    :primitive_method,
    :promise_resolver
  ]

  @doc "Returns whether a VM value is callable by JavaScript."
  @spec callable?(term(), State.t()) :: boolean()
  def callable?(value, execution), do: typeof(value, execution) == "function"

  @doc "Returns the JavaScript `typeof` classification for a represented value."
  @spec typeof(term(), State.t()) :: String.t()
  def typeof(%Reference{} = reference, execution) do
    if BuiltinRuntime.callable(execution, reference), do: "function", else: "object"
  end

  def typeof(value, _execution)
      when is_tuple(value) and elem(value, 0) in @callable_tags,
      do: "function"

  def typeof(value, _execution), do: Value.typeof(value)
end
