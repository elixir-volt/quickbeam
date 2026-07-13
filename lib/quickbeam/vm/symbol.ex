defmodule QuickBEAM.VM.Symbol do
  @moduledoc "Defines an owner-independent well-known JavaScript Symbol value."

  @enforce_keys [:id, :description]
  defstruct [:id, :description]

  @type t :: %__MODULE__{
          id: atom() | {:global, String.t()} | {:local, non_neg_integer()},
          description: String.t()
        }

  @doc "Returns the stable `Symbol.iterator` value used as a property key."
  @spec iterator() :: t()
  def iterator, do: %__MODULE__{id: :iterator, description: "Symbol.iterator"}
end
