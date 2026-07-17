defmodule QuickBEAM.VM.Program do
  @moduledoc """
  Defines an immutable decoded JavaScript program.

  `bytecode_digest` identifies the serialized QuickJS input. `source_digest` is
  also present when the public source compiler produced the program. The
  binary `pin_key` includes version, digest, and filename identity so bounded
  pinned storage never derives atoms from input.

  The fields are an advanced, version-locked decoded representation, not a
  construction API. Obtain valid values through `QuickBEAM.VM.compile/2` or
  `QuickBEAM.VM.decode/2`; changing fields invalidates verification guarantees.
  """

  @enforce_keys [:version, :fingerprint, :atoms, :root]
  defstruct [
    :version,
    :fingerprint,
    :atoms,
    :root,
    :bytecode_digest,
    :bytecode_size,
    :source_digest,
    :pin_key
  ]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          fingerprint: String.t(),
          atoms: tuple(),
          root: QuickBEAM.VM.Program.Function.t(),
          bytecode_digest: binary() | nil,
          bytecode_size: non_neg_integer() | nil,
          source_digest: binary() | nil,
          pin_key: binary() | nil
        }
end
