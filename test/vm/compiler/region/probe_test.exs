defmodule QuickBEAM.VM.Compiler.Region.ProbeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Context
  alias QuickBEAM.VM.Compiler.Region.Probe
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.State

  test "samples fixed-capacity integer regions in the evaluation owner" do
    execution = execution()

    execution =
      Enum.reduce(0..64, execution, fn region, execution ->
        frame = frame(region, region * 64)

        Enum.reduce(1..16, execution, fn _sample, execution ->
          Probe.observe(execution, frame)
        end)
      end)

    snapshot = Probe.snapshot(execution)
    assert snapshot.sample_interval == 16
    assert snapshot.window_size == 64
    assert snapshot.total_samples == 65
    assert length(snapshot.regions) == 64
    assert Enum.all?(snapshot.regions, &is_integer(&1.function_id))
    assert Enum.all?(snapshot.regions, &is_integer(&1.entry_pc))

    assert Task.await(Task.async(fn -> Probe.snapshot(execution) end)) == nil
  end

  defp execution do
    %State{
      atoms: {},
      compiler_context: %Context{
        pool: self(),
        program: %Program{version: 26, fingerprint: "test", atoms: {}, root: nil},
        region_probe: Probe.new()
      },
      max_stack_depth: 8,
      remaining_steps: 8,
      step_limit: 8
    }
  end

  defp frame(function_id, pc) do
    function = %Function{id: function_id}
    %Frame{function: function, callable: function, locals: {}, args: {}, pc: pc}
  end
end
