defmodule QuickBEAM.VM.Program do
  @moduledoc """
  Defines an immutable decoded JavaScript program.

  `bytecode_digest` identifies the serialized QuickJS input. `source_digest` is
  also present when the public source compiler produced the program. The
  binary `pin_key` includes version, digest, and filename identity so bounded
  pinned storage never derives atoms from input.
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
          root: term(),
          bytecode_digest: binary() | nil,
          bytecode_size: non_neg_integer() | nil,
          source_digest: binary() | nil,
          pin_key: binary() | nil
        }

  @doc "Derives the binary identity used by bounded immutable program sharing."
  @spec put_pin_key(t()) :: t()
  def put_pin_key(%__MODULE__{} = program) do
    filename = if is_map(program.root), do: Map.get(program.root, :filename), else: nil

    identity =
      {:quickbeam_vm_program_v1, program.version, program.fingerprint, program.bytecode_digest,
       program.source_digest, filename}

    %{program | pin_key: :crypto.hash(:sha256, :erlang.term_to_binary(identity))}
  end
end
