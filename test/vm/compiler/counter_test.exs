defmodule QuickBEAM.VM.Compiler.CounterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Context
  alias QuickBEAM.VM.Compiler.Counter
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Program

  test "keeps fixed OTP counters in the evaluation owner" do
    execution = %State{
      atoms: {},
      compiler_context: %Context{
        counters: Counter.new(),
        pool: self(),
        program: %Program{version: 26, fingerprint: "test", atoms: {}, root: nil}
      },
      max_stack_depth: 8,
      remaining_steps: 8,
      step_limit: 8
    }

    execution = Counter.increment(execution, :frame_attempts)
    assert Counter.snapshot(execution).frame_attempts == 1

    task =
      Task.async(fn ->
        foreign = Counter.increment(execution, :frame_attempts)
        Counter.snapshot(foreign)
      end)

    assert Task.await(task) == nil
    assert Counter.snapshot(execution).frame_attempts == 1
    assert map_size(Counter.snapshot(execution).deopt_opcodes) == 0
  end
end
