defmodule QuickBEAM.VM.Compiler.Contract do
  @moduledoc """
  Defines bounded identities for the optional BEAM compiler tier.

  Artifact keys are binaries and module slots are a fixed compile-time atom set.
  Calling this module for unbounded user programs therefore cannot grow the atom
  table. Compiler implementations must not construct additional module names.
  """

  alias QuickBEAM.VM.{Function, Program}

  @contract_version 1
  @runtime_abi_version 4
  @artifact_key_bytes 32
  @profiles [:pure_v1, :scalar_v1]

  @pool_modules [
    QuickBEAM.VM.Compiler.Slot00,
    QuickBEAM.VM.Compiler.Slot01,
    QuickBEAM.VM.Compiler.Slot02,
    QuickBEAM.VM.Compiler.Slot03,
    QuickBEAM.VM.Compiler.Slot04,
    QuickBEAM.VM.Compiler.Slot05,
    QuickBEAM.VM.Compiler.Slot06,
    QuickBEAM.VM.Compiler.Slot07,
    QuickBEAM.VM.Compiler.Slot08,
    QuickBEAM.VM.Compiler.Slot09,
    QuickBEAM.VM.Compiler.Slot10,
    QuickBEAM.VM.Compiler.Slot11,
    QuickBEAM.VM.Compiler.Slot12,
    QuickBEAM.VM.Compiler.Slot13,
    QuickBEAM.VM.Compiler.Slot14,
    QuickBEAM.VM.Compiler.Slot15,
    QuickBEAM.VM.Compiler.Slot16,
    QuickBEAM.VM.Compiler.Slot17,
    QuickBEAM.VM.Compiler.Slot18,
    QuickBEAM.VM.Compiler.Slot19,
    QuickBEAM.VM.Compiler.Slot20,
    QuickBEAM.VM.Compiler.Slot21,
    QuickBEAM.VM.Compiler.Slot22,
    QuickBEAM.VM.Compiler.Slot23,
    QuickBEAM.VM.Compiler.Slot24,
    QuickBEAM.VM.Compiler.Slot25,
    QuickBEAM.VM.Compiler.Slot26,
    QuickBEAM.VM.Compiler.Slot27,
    QuickBEAM.VM.Compiler.Slot28,
    QuickBEAM.VM.Compiler.Slot29,
    QuickBEAM.VM.Compiler.Slot30,
    QuickBEAM.VM.Compiler.Slot31
  ]

  @doc "Returns the compiler contract version included in every artifact key."
  @spec version() :: pos_integer()
  def version, do: @contract_version

  @doc "Returns the generated-code runtime ABI version."
  @spec runtime_abi_version() :: pos_integer()
  def runtime_abi_version, do: @runtime_abi_version

  @doc "Returns the exact byte width of compiler artifact keys."
  @spec artifact_key_bytes() :: pos_integer()
  def artifact_key_bytes, do: @artifact_key_bytes

  @doc "Returns the immutable, bounded module atom pool."
  @spec pool_modules() :: [module()]
  def pool_modules, do: @pool_modules

  @doc "Returns the maximum number of compiler modules that may be loaded."
  @spec pool_capacity() :: pos_integer()
  def pool_capacity, do: length(@pool_modules)

  @doc "Builds a deterministic binary namespace for one immutable verified program."
  @spec program_identity(Program.t()) :: {:ok, binary()} | {:error, term()}
  def program_identity(%Program{} = program) do
    payload = {
      @contract_version,
      @runtime_abi_version,
      program.version,
      program.fingerprint,
      program.bytecode_digest,
      program.source_digest,
      program.atoms
    }

    {:ok, digest(payload)}
  end

  def program_identity(program), do: {:error, {:invalid_artifact_program, program}}

  @doc "Builds a deterministic binary identity for one verified function artifact."
  @spec artifact_key(Program.t(), Function.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def artifact_key(program, function, opts \\ [])

  def artifact_key(%Program{} = program, %Function{} = function, opts)
      when is_list(opts) do
    with :ok <- validate_options(opts),
         profile = Keyword.get(opts, :profile, :pure_v1),
         :ok <- validate_profile(profile),
         {:ok, program_identity} <- program_identity(program) do
      artifact_key_from_identity(program_identity, function, profile: profile)
    end
  end

  def artifact_key(program, function, _opts),
    do: {:error, {:invalid_artifact_input, program, function}}

  @doc "Builds an artifact key from a previously validated program namespace."
  @spec artifact_key_from_identity(binary(), Function.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def artifact_key_from_identity(program_identity, function, opts \\ [])

  def artifact_key_from_identity(program_identity, %Function{} = function, opts)
      when is_binary(program_identity) and byte_size(program_identity) == @artifact_key_bytes and
             is_list(opts) do
    with :ok <- validate_options(opts),
         profile = Keyword.get(opts, :profile, :pure_v1),
         :ok <- validate_profile(profile) do
      payload = {program_identity, strip_repeated_atoms(function), profile}
      {:ok, digest(payload)}
    end
  end

  def artifact_key_from_identity(program_identity, function, _opts),
    do: {:error, {:invalid_artifact_identity, program_identity, function}}

  defp strip_repeated_atoms(%Function{} = function) do
    constants = Enum.map(function.constants, &strip_repeated_atoms/1)
    %{function | atoms: nil, constants: constants}
  end

  defp strip_repeated_atoms(value), do: value

  defp digest(value) do
    binary = :erlang.term_to_binary(value, [:deterministic])
    :crypto.hash(:sha256, binary)
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- [:profile] do
        [] -> :ok
        [key | _rest] -> {:error, {:unknown_option, key}}
      end
    else
      {:error, {:invalid_option, :options, opts}}
    end
  end

  defp validate_profile(profile) when profile in @profiles, do: :ok
  defp validate_profile(profile), do: {:error, {:unsupported_compiler_profile, profile}}
end
