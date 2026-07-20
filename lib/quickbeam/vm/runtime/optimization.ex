defmodule QuickBEAM.VM.Runtime.Optimization do
  @moduledoc """
  Dispatches optional optimization hooks without coupling canonical runtime code
  to a specific compiler implementation.

  Hook and executor modules are fixed by the owner-local optimization context;
  ordinary interpreter evaluations carry no context and pay only bounded map
  checks.
  """

  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.State

  @doc "Executes one frame through the configured owner-local optimizer."
  @spec execute_frame(Frame.t(), State.t()) :: term()
  def execute_frame(
        %Frame{} = frame,
        %State{compiler_context: %{executor: executor}} = execution
      )
      when is_atom(executor),
      do: executor.execute_frame(frame, execution)

  @doc "Checks whether an optimizer action contains its configured deoptimization type."
  @spec deopt?(term(), State.t()) :: boolean()
  def deopt?(
        %{__struct__: deopt_module},
        %State{compiler_context: %{deopt_module: deopt_module}}
      ),
      do: true

  def deopt?(_value, %State{}), do: false

  @doc "Validates an opaque deoptimization through its defining module."
  @spec validate_deopt(struct()) :: :ok | {:error, term()}
  def validate_deopt(%{__struct__: module} = deopt) when is_atom(module) do
    if function_exported?(module, :validate, 1),
      do: module.validate(deopt),
      else: {:error, {:invalid_deopt_module, module}}
  end

  @doc "Increments one optimizer event when instrumentation is configured."
  @spec increment(State.t(), atom()) :: State.t()
  def increment(%State{} = execution, event),
    do: instrument(execution, :increment, [execution, event], execution)

  @doc "Records one interpreted opcode when instrumentation is configured."
  @spec interpreted_opcode(State.t(), non_neg_integer()) :: State.t()
  def interpreted_opcode(%State{} = execution, opcode),
    do: instrument(execution, :interpreted_opcode, [execution, opcode], execution)

  @doc "Samples one interpreted frame when instrumentation is configured."
  @spec observe(State.t(), Frame.t()) :: State.t()
  def observe(%State{} = execution, %Frame{} = frame),
    do: instrument(execution, :observe, [execution, frame], execution)

  @doc "Returns optimizer-specific endpoint observations, or empty observations."
  @spec snapshot(State.t()) :: map()
  def snapshot(%State{} = execution),
    do:
      instrument(
        execution,
        :snapshot,
        [execution],
        %{compiler_counters: nil, compiler_regions: nil}
      )

  defp instrument(
         %State{compiler_context: %{instrumentation: instrumentation}},
         function,
         arguments,
         _default
       )
       when is_atom(instrumentation) and not is_nil(instrumentation),
       do: apply(instrumentation, function, arguments)

  defp instrument(%State{}, _function, _arguments, default), do: default
end
