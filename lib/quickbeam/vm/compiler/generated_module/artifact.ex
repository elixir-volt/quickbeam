defmodule QuickBEAM.VM.Compiler.GeneratedModule.Artifact do
  @moduledoc """
  Represents a validated slot-specific generated module binary.

  The digest is checked again immediately before installation so an artifact
  cannot be substituted between emission and code loading.
  """

  @max_binary_bytes 8 * 1024 * 1024

  @enforce_keys [:module, :binary, :digest]
  defstruct [:module, :binary, :digest]

  @type t :: %__MODULE__{module: module(), binary: binary(), digest: binary()}

  @doc "Creates an artifact after enforcing the generated binary size limit."
  @spec new(module(), binary()) :: {:ok, t()} | {:error, term()}
  def new(module, binary) when is_atom(module) and is_binary(binary) do
    if byte_size(binary) <= @max_binary_bytes do
      {:ok, %__MODULE__{module: module, binary: binary, digest: digest(binary)}}
    else
      {:error, {:compiler_resource_limit, :module_bytes, byte_size(binary), @max_binary_bytes}}
    end
  end

  def new(module, binary), do: {:error, {:invalid_generated_module_binary, module, binary}}

  @doc "Revalidates an artifact's binary size and digest before installation."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{binary: binary, digest: expected}) when is_binary(binary) do
    cond do
      byte_size(binary) > @max_binary_bytes ->
        {:error, {:compiler_resource_limit, :module_bytes, byte_size(binary), @max_binary_bytes}}

      expected != digest(binary) ->
        {:error, :artifact_digest_mismatch}

      true ->
        :ok
    end
  end

  def validate(artifact), do: {:error, {:invalid_generated_module_artifact, artifact}}

  defp digest(binary), do: :crypto.hash(:sha256, binary)
end
