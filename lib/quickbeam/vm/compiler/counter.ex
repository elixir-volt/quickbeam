defmodule QuickBEAM.VM.Compiler.Counter do
  @moduledoc """
  Owns bounded compiler counters for one evaluation through OTP `:counters`.

  The reference is created with the evaluation's compiler context, remains in
  that evaluation owner, and is read into a fixed-key map only at the measurement
  boundary. Generated-step, entry, deoptimization, invocation, and re-entry
  values describe execution through a fixed compiler profile. Compilation,
  cache, and skip-decision values are lifecycle observations and can differ with
  module-pool state.
  """

  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Bytecode.Opcode

  @indexes %{
    frame_attempts: 1,
    generated_entries: 2,
    generated_steps: 3,
    compiled_functions: 4,
    cached_functions: 5,
    skipped_functions: 6,
    skipped_frames: 7,
    deoptimizations: 8,
    unsupported_opcode_deopts: 9,
    unsupported_semantics_deopts: 10,
    step_boundary_deopts: 11,
    suspension_boundary_deopts: 12,
    guard_failed_deopts: 13,
    invocation_actions: 14,
    reentries: 15,
    region_attempts: 16,
    region_cold: 17,
    region_hot: 18,
    region_compiled: 19
  }
  @event_count map_size(@indexes)
  @opcode_slots 256
  @deopt_opcode_offset @event_count
  @interpreted_opcode_offset @event_count + @opcode_slots
  @counter_count @event_count + 2 * @opcode_slots
  @events Map.keys(@indexes)

  @enforce_keys [:owner, :reference]
  defstruct [:owner, :reference]

  @type t :: %__MODULE__{owner: pid(), reference: term()}

  @doc "Creates one fixed-size counter set without cross-process write concurrency."
  @spec new() :: t()
  def new,
    do: %__MODULE__{owner: self(), reference: :counters.new(@counter_count, [])}

  @doc "Increments one fixed compiler event in an evaluation-owned context."
  @spec increment(State.t(), atom()) :: State.t()
  def increment(
        %State{
          compiler_context: %{counters: %__MODULE__{owner: owner, reference: reference}}
        } = execution,
        event
      )
      when owner == self() and event in @events do
    :counters.add(reference, Map.fetch!(@indexes, event), 1)
    execution
  end

  def increment(%State{} = execution, _event), do: execution

  @doc "Adds an exact generated instruction count to owner-local counters."
  @spec add_generated_steps(State.t(), non_neg_integer()) :: State.t()
  def add_generated_steps(
        %State{
          compiler_context: %{counters: %__MODULE__{owner: owner, reference: reference}}
        } = execution,
        count
      )
      when owner == self() and is_integer(count) and count > 0 do
    :counters.add(reference, Map.fetch!(@indexes, :generated_steps), count)
    execution
  end

  def add_generated_steps(%State{} = execution, _count), do: execution

  @doc "Records one interpreted opcode while compiler measurement is enabled."
  @spec interpreted_opcode(State.t(), non_neg_integer()) :: State.t()
  def interpreted_opcode(
        %State{
          compiler_context: %{counters: %__MODULE__{owner: owner, reference: reference}}
        } = execution,
        opcode
      )
      when owner == self() and is_integer(opcode) and opcode in 0..255 do
    :counters.add(reference, @interpreted_opcode_offset + opcode + 1, 1)
    execution
  end

  def interpreted_opcode(%State{} = execution, _opcode), do: execution

  @doc "Records one validated compiler deoptimization reason and opcode."
  @spec deopt(State.t(), term(), Frame.t()) :: State.t()
  def deopt(%State{} = execution, reason, %Frame{} = frame) do
    execution
    |> increment(:deoptimizations)
    |> increment(deopt_event(reason))
    |> increment_deopt_opcode(frame)
  end

  @doc "Returns a fixed-key compiler counter map for endpoint measurement."
  @spec snapshot(State.t()) :: map() | nil
  def snapshot(%State{
        compiler_context: %{
          profile: profile,
          counters: %__MODULE__{owner: owner, reference: reference}
        }
      })
      when owner == self() do
    Map.new(@indexes, fn {name, index} -> {name, :counters.get(reference, index)} end)
    |> Map.put(:deopt_opcodes, opcode_counts(reference, @deopt_opcode_offset))
    |> Map.put(:interpreted_opcodes, opcode_counts(reference, @interpreted_opcode_offset))
    |> Map.put(:profile, profile)
  end

  def snapshot(%State{}), do: nil

  defp increment_deopt_opcode(
         %State{
           compiler_context: %{counters: %__MODULE__{owner: owner, reference: reference}}
         } = execution,
         %Frame{pc: pc, function: %{instructions: instructions}}
       )
       when owner == self() and is_integer(pc) and pc >= 0 and is_tuple(instructions) and
              pc < tuple_size(instructions) do
    {opcode, _operands} = elem(instructions, pc)

    if is_integer(opcode) and opcode in 0..255,
      do: :counters.add(reference, @deopt_opcode_offset + opcode + 1, 1)

    execution
  end

  defp increment_deopt_opcode(%State{} = execution, _frame), do: execution

  defp opcode_counts(reference, offset) do
    Opcode.table()
    |> Enum.reduce(%{}, fn {opcode, {name, _size, _pops, _pushes, _format}}, counts ->
      count = :counters.get(reference, offset + opcode + 1)
      if count == 0, do: counts, else: Map.put(counts, name, count)
    end)
  end

  defp deopt_event(:unsupported_opcode), do: :unsupported_opcode_deopts
  defp deopt_event(:unsupported_semantics), do: :unsupported_semantics_deopts
  defp deopt_event(:step_boundary), do: :step_boundary_deopts
  defp deopt_event(:suspension_boundary), do: :suspension_boundary_deopts
  defp deopt_event({:guard_failed, _guard}), do: :guard_failed_deopts
  defp deopt_event(_reason), do: :unsupported_semantics_deopts
end
