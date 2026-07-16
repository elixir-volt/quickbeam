defmodule QuickBEAM.VM.CompilerCountersTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.{Context, Counters}
  alias QuickBEAM.VM.{Execution, Program}

  test "keeps fixed OTP counters in the evaluation owner" do
    execution = %Execution{
      atoms: {},
      compiler_context: %Context{
        counters: Counters.new(),
        pool: self(),
        program: %Program{version: 26, fingerprint: "test", atoms: {}, root: nil}
      },
      max_stack_depth: 8,
      remaining_steps: 8,
      step_limit: 8
    }

    execution = Counters.increment(execution, :frame_attempts)
    assert Counters.snapshot(execution).frame_attempts == 1

    task =
      Task.async(fn ->
        foreign = Counters.increment(execution, :frame_attempts)
        Counters.snapshot(foreign)
      end)

    assert Task.await(task) == nil
    assert Counters.snapshot(execution).frame_attempts == 1
    assert map_size(Counters.snapshot(execution).deopt_opcodes) == 0
  end
end
