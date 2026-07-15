defmodule QuickBEAM.VM.Compiler.GeneratedModule.Template do
  @moduledoc """
  Holds bounded Erlang abstract forms before assignment to a static module slot.

  Templates use the reserved `QuickBEAM.VM.Compiler.GeneratedModule.Placeholder`
  atom as their module attribute. The emitter replaces only that attribute with
  the leased static module name.
  """

  @placeholder_module QuickBEAM.VM.Compiler.GeneratedModule.Placeholder

  @enforce_keys [:forms]
  defstruct [:forms]

  @type t :: %__MODULE__{forms: [tuple()]}

  @doc "Returns the sole module atom accepted in unassigned compiler forms."
  @spec placeholder_module() :: module()
  def placeholder_module, do: @placeholder_module
end
