defmodule QuickBEAM.VM.Program do
  @moduledoc """
  Defines an immutable decoded JavaScript program.

  `bytecode_digest` identifies the serialized QuickJS input. `source_digest` is
  also present when the public source compiler produced the program, allowing
  optional compiler caches to invalidate on either identity without retaining
  source text.
  """

  @enforce_keys [:version, :fingerprint, :atoms, :root]
  defstruct [:version, :fingerprint, :atoms, :root, :bytecode_digest, :source_digest]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          fingerprint: String.t(),
          atoms: tuple(),
          root: term(),
          bytecode_digest: binary() | nil,
          source_digest: binary() | nil
        }
end
