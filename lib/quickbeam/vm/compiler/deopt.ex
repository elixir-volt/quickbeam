defmodule QuickBEAM.VM.Compiler.Deopt do
  @moduledoc """
  Represents a validated before-instruction transition to the interpreter.

  Deoptimization state is owner-local. Its frame points at the next unexecuted
  verified instruction, and that instruction has neither consumed a step nor
  performed an observable effect.
  """

  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.State

  @contract_version Contract.version()
  @artifact_key_bytes Contract.artifact_key_bytes()

  @enforce_keys [
    :artifact_key,
    :pool_epoch,
    :generation,
    :reason,
    :owner,
    :frame,
    :execution
  ]
  defstruct [
    :artifact_key,
    :pool_epoch,
    :generation,
    :reason,
    :owner,
    :frame,
    :execution,
    contract_version: Contract.version(),
    phase: :before_instruction
  ]

  @type reason ::
          :unsupported_opcode
          | :unsupported_semantics
          | :step_boundary
          | :suspension_boundary
          | {:guard_failed, atom()}

  @type t :: %__MODULE__{
          artifact_key: binary(),
          pool_epoch: non_neg_integer(),
          generation: non_neg_integer(),
          reason: reason(),
          owner: pid(),
          frame: Frame.t(),
          execution: State.t(),
          contract_version: pos_integer(),
          phase: :before_instruction
        }

  @doc "Builds owner-local deoptimization state and validates its boundary."
  @spec new(reason(), binary(), non_neg_integer(), non_neg_integer(), Frame.t(), State.t()) ::
          {:ok, t()} | {:error, term()}
  def new(
        reason,
        artifact_key,
        pool_epoch,
        generation,
        %Frame{} = frame,
        %State{} = execution
      ) do
    deopt = %__MODULE__{
      artifact_key: artifact_key,
      pool_epoch: pool_epoch,
      generation: generation,
      reason: reason,
      owner: self(),
      frame: frame,
      execution: execution
    }

    case validate(deopt) do
      :ok -> {:ok, deopt}
      {:error, _reason} = error -> error
    end
  end

  def new(reason, artifact_key, pool_epoch, generation, frame, execution),
    do:
      {:error,
       {:invalid_deopt_state, reason, artifact_key, pool_epoch, generation, frame, execution}}

  @doc "Validates the owner, contract identity, reason, and instruction boundary."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = deopt) do
    with :ok <- validate_contract(deopt.contract_version),
         :ok <- validate_key(deopt.artifact_key),
         :ok <- validate_counter(:pool_epoch, deopt.pool_epoch),
         :ok <- validate_counter(:generation, deopt.generation),
         :ok <- validate_owner(deopt.owner),
         :ok <- validate_phase(deopt.phase),
         :ok <- validate_reason(deopt.reason),
         :ok <- validate_boundary(deopt.frame) do
      validate_execution(deopt.execution)
    end
  end

  def validate(value), do: {:error, {:invalid_deopt, value}}

  defp validate_contract(@contract_version), do: :ok
  defp validate_contract(version), do: {:error, {:stale_compiler_contract, version}}

  defp validate_key(key)
       when is_binary(key) and byte_size(key) == @artifact_key_bytes,
       do: :ok

  defp validate_key(key), do: {:error, {:invalid_artifact_key, key}}

  defp validate_counter(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_counter(name, value), do: {:error, {:invalid_deopt_counter, name, value}}

  defp validate_owner(owner) when owner == self(), do: :ok
  defp validate_owner(owner), do: {:error, {:deopt_owner_mismatch, owner, self()}}

  defp validate_phase(:before_instruction), do: :ok
  defp validate_phase(phase), do: {:error, {:unsupported_deopt_phase, phase}}

  defp validate_reason(reason)
       when reason in [
              :unsupported_opcode,
              :unsupported_semantics,
              :step_boundary,
              :suspension_boundary
            ],
       do: :ok

  defp validate_reason({:guard_failed, guard}) when is_atom(guard), do: :ok
  defp validate_reason(reason), do: {:error, {:invalid_deopt_reason, reason}}

  defp validate_boundary(%Frame{pc: pc, function: %{instructions: instructions}})
       when is_integer(pc) and pc >= 0 and is_tuple(instructions) and
              pc < tuple_size(instructions),
       do: :ok

  defp validate_boundary(frame), do: {:error, {:invalid_deopt_boundary, frame}}

  defp validate_execution(%State{}), do: :ok
  defp validate_execution(execution), do: {:error, {:invalid_deopt_execution, execution}}
end
