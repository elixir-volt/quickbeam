defmodule QuickBEAM.VM.Program.Identity do
  @moduledoc """
  Derives the stable binary identity used by bounded program pinning.

  Identities include the bytecode ABI, serialized and source digests, and the
  recursively assigned filename. They never create atoms from program input.
  """

  alias QuickBEAM.VM.Program

  @doc "Adds the stable pin identity to a decoded program."
  @spec put(Program.t()) :: Program.t()
  def put(%Program{} = program) do
    filename = if is_map(program.root), do: Map.get(program.root, :filename), else: nil

    identity =
      {:quickbeam_vm_program_v1, program.version, program.fingerprint, program.bytecode_digest,
       program.source_digest, filename}

    %{program | pin_key: :crypto.hash(:sha256, :erlang.term_to_binary(identity))}
  end
end
