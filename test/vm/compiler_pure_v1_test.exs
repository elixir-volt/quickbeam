defmodule QuickBEAM.VM.CompilerPureV1Test do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.{Contract, Deopt, GeneratedModule, ModulePool, Runtime}
  alias QuickBEAM.VM.Compiler.GeneratedModule.{Emitter, ImportPolicy}
  alias QuickBEAM.VM.Compiler.Lowering.PureV1
  alias QuickBEAM.VM.{Execution, Frame, Function, Interpreter, Invocation, Opcodes, Program}

  test "builds deterministic CFG blocks with canonical successors and predecessors" do
    function = branch_function()
    assert {:ok, blocks} = CFG.analyze(function)

    assert Enum.map(blocks, &{&1.start_pc, &1.end_pc}) == [{0, 1}, {2, 3}, {4, 4}, {5, 5}]

    assert [first, second, third, fourth] = blocks
    assert first.successors == [4, 2]
    assert first.predecessors == []
    assert second.successors == [5]
    assert second.predecessors == [0]
    assert third.successors == [5]
    assert third.predecessors == [0]
    assert fourth.successors == []
    assert fourth.predecessors == [2, 4]

    assert [{0, :push_true, []}, {1, :if_false, [4]}] = first.instructions
  end

  test "rejects malformed CFG targets even when analysis is called outside verification" do
    function = %Function{
      id: 0,
      atoms: {},
      instructions: {instruction(:goto, [99]), instruction(:return_undef)}
    }

    assert {:error, {:invalid_compiler_target, 99}} = CFG.analyze(function)

    malformed = %{
      function
      | instructions: {instruction(:goto, [:invalid]), instruction(:return_undef)}
    }

    assert {:error, {:invalid_compiler_target, :invalid}} = CFG.analyze(malformed)
  end

  test "emits bounded pure plans with explicit unsupported boundaries" do
    function = arithmetic_function()

    assert {:ok,
            %{
              0 =>
                {[
                   {:stack, :push_i32, [40]},
                   {:stack, :push_i32, [2]},
                   {:value, :add, []}
                 ], :unsupported_opcode}
            }} = PureV1.plan(function)

    assert {:ok, template} = PureV1.lower(function)
    module = hd(Contract.pool_modules())
    assert {:ok, artifact} = Emitter.emit(key(1), module, template)

    assert {:ok, imports} = ImportPolicy.imports(artifact.binary)
    assert {Runtime, :execute_plan, 4} in imports
  end

  test "lowering unbounded function values does not allocate per-program atoms" do
    function = arithmetic_function()
    assert {:ok, _template} = PureV1.lower(function)
    atom_count = :erlang.system_info(:atom_count)

    for value <- 1..10_000 do
      instructions = put_elem(function.instructions, 0, instruction(:push_i32, [value]))
      assert {:ok, _template} = PureV1.lower(%{function | id: value, instructions: instructions})
    end

    assert :erlang.system_info(:atom_count) == atom_count
  end

  test "marks async instructions as explicit suspension boundaries" do
    function = %Function{
      id: 0,
      atoms: {},
      instructions: {
        instruction(:undefined),
        instruction(:await),
        instruction(:return_async)
      },
      stack_size: 1
    }

    assert {:ok,
            %{
              0 => {[{:stack, :undefined, []}], :suspension_boundary},
              2 => {[], :unsupported_opcode}
            }} = PureV1.plan(function)
  end

  test "caps one generated block plan at 256 instructions" do
    instructions =
      List.to_tuple(List.duplicate(instruction(:push_i32, [1]), 300) ++ [instruction(:return)])

    function = %Function{id: 0, atoms: {}, instructions: instructions, stack_size: 300}
    assert {:ok, %{0 => {operations, :unsupported_semantics}}} = PureV1.plan(function)
    assert length(operations) == 256
  end

  test "runs a lowered pure prefix and resumes the interpreter before return" do
    function = arithmetic_function()
    program = program(function)
    pool = start_pool()

    assert {:ok, template} = PureV1.lower(function)
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)

    frame = frame(function)
    execution = execution(4)

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame, execution)

    assert deopt.reason == :unsupported_opcode
    assert deopt.frame.pc == 3
    assert deopt.frame.stack == [42]
    assert deopt.execution.remaining_steps == 1
    assert :ok = ModulePool.checkin(pool, lease)

    assert Interpreter.resume_deopt(deopt) == {:ok, 42}
    assert Interpreter.eval(program, max_steps: 4) == {:ok, 42}
  end

  test "preserves exact step rejection across compiled-to-interpreter deoptimization" do
    function = arithmetic_function()
    program = program(function)
    pool = start_pool()

    assert {:ok, template} = PureV1.lower(function)
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame(function), execution(3))

    assert deopt.execution.remaining_steps == 0
    assert :ok = ModulePool.checkin(pool, lease)

    expected = {:error, {:limit_exceeded, :steps, 3}}
    assert Interpreter.resume_deopt(deopt) == expected
    assert Interpreter.eval(program, max_steps: 3) == expected
  end

  test "lowers decoded v26 arithmetic before resuming its unsupported return" do
    assert {:ok, %Program{root: function} = program} = QuickBEAM.VM.compile("40 + 2")
    pool = start_pool()

    assert {:ok, template} = PureV1.lower(function)
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)

    frame = Invocation.new_frame(function, function, [], :undefined, {})
    execution = %{execution(100) | atoms: program.atoms}

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame, execution)

    assert deopt.frame.pc > 0
    assert :ok = ModulePool.checkin(pool, lease)
    assert Interpreter.resume_deopt(deopt) == QuickBEAM.VM.eval(program, max_steps: 100)
  end

  test "executes a compiled branch before deoptimizing at its selected successor" do
    function = branch_function()
    program = program(function)
    pool = start_pool()

    assert {:ok, template} = PureV1.lower(function)
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame(function), execution(10))

    assert deopt.reason == :unsupported_semantics
    assert deopt.frame.pc == 2
    assert deopt.frame.stack == []
    assert deopt.execution.remaining_steps == 8
    assert :ok = ModulePool.checkin(pool, lease)

    assert Interpreter.resume_deopt(deopt) == {:ok, 10}
    assert Interpreter.eval(program, max_steps: 10) == {:ok, 10}
  end

  defp start_pool do
    start_supervised!(
      {ModulePool,
       backend: GeneratedModule, task_supervisor: QuickBEAM.VM.TaskSupervisor, capacity: 1}
    )
  end

  defp arithmetic_function do
    %Function{
      id: 0,
      atoms: {},
      instructions: {
        instruction(:push_i32, [40]),
        instruction(:push_i32, [2]),
        instruction(:add),
        instruction(:return)
      },
      stack_size: 2
    }
  end

  defp branch_function do
    %Function{
      id: 0,
      atoms: {},
      instructions: {
        instruction(:push_true),
        instruction(:if_false, [4]),
        instruction(:push_i32, [10]),
        instruction(:goto, [5]),
        instruction(:push_i32, [20]),
        instruction(:return)
      },
      stack_size: 1
    }
  end

  defp instruction(name, operands \\ []), do: {Opcodes.num(name), operands}

  defp program(function) do
    %Program{
      version: 26,
      fingerprint: "pure-v1-test",
      atoms: {},
      root: function
    }
  end

  defp frame(function) do
    %Frame{
      function: function,
      callable: function,
      locals: {},
      args: {},
      this: :undefined
    }
  end

  defp execution(steps) do
    %Execution{
      atoms: {},
      max_stack_depth: 32,
      remaining_steps: steps,
      step_limit: steps
    }
  end

  defp key(integer), do: :crypto.hash(:sha256, <<integer::unsigned-64>>)
end
