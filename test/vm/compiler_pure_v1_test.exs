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

  test "prefilters only obviously small non-loop nested candidates" do
    assert {:ok, small_program} = QuickBEAM.VM.compile("(function(value){return value+1})(41)")
    small = Enum.find(small_program.root.constants, &is_struct(&1, Function))
    refute PureV1.candidate?(small, 32, :pure_v1)
    refute PureV1.candidate?(small, 32, :scalar_v1)
    assert PureV1.candidate?(small, 1, :pure_v1)

    assert {:ok, loop_program} =
             QuickBEAM.VM.compile("(function(n){while(n>0)n--;return n})(10)")

    loop = Enum.find(loop_program.root.constants, &is_struct(&1, Function))
    assert PureV1.candidate?(loop, 10_000, :pure_v1)
    assert PureV1.candidate?(loop, 10_000, :scalar_v1)
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

    assert {:skip, 3} = PureV1.prepare(function, 4)
    assert {:ok, prepared, 3} = PureV1.prepare(function, 3)
    assert {:ok, template} = PureV1.lower(function)
    assert prepared == template

    assert [:run, :block] ==
             for({:function, _line, name, _arity, _clauses} <- template.forms, do: name)

    module = hd(Contract.pool_modules())
    assert {:ok, artifact} = Emitter.emit(key(1), module, template)

    assert {:ok, imports} = ImportPolicy.imports(artifact.binary)
    assert {Runtime, :deopt_state, 4} in imports
    refute {Runtime, :binary, 3} in imports
    refute {Runtime, :execute_fast_block, 4} in imports
    refute {Runtime, :execute_stack, 4} in imports
    refute {Runtime, :execute_value, 4} in imports
    refute {Runtime, :execute_plan, 4} in imports
  end

  test "lowering unbounded function values does not allocate per-program atoms" do
    function = arithmetic_function()

    for value <- 1..100 do
      instructions = put_elem(function.instructions, 0, instruction(:push_i32, [value]))
      assert {:ok, _template} = PureV1.lower(%{function | id: value, instructions: instructions})
    end

    atom_count = :erlang.system_info(:atom_count)

    for value <- 1..10_000 do
      instructions = put_elem(function.instructions, 0, instruction(:push_i32, [value]))
      assert {:ok, _template} = PureV1.lower(%{function | id: value, instructions: instructions})
    end

    assert :erlang.system_info(:atom_count) == atom_count
  end

  test "repeated specialized module emission reuses fixed module and form atoms" do
    pool = start_pool()
    function = arithmetic_function()

    emit = fn value ->
      instructions = put_elem(function.instructions, 0, instruction(:push_i32, [value]))
      function = %{function | id: value, instructions: instructions}
      assert {:ok, template} = PureV1.lower(function)
      assert {:ok, artifact_key} = Contract.artifact_key(program(function), function)
      assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)
      assert :ok = ModulePool.checkin(pool, lease)
    end

    Enum.each(1..5, emit)
    atom_count = :erlang.system_info(:atom_count)
    Enum.each(6..105, emit)
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

  test "rejects functions exceeding specialized block and instruction caps" do
    too_many_blocks =
      for(pc <- 0..4_096, do: instruction(:goto, [pc + 1])) ++ [instruction(:return_undef)]

    function = %Function{
      id: 0,
      atoms: {},
      instructions: List.to_tuple(too_many_blocks),
      stack_size: 0
    }

    assert {:error, {:compiler_resource_limit, :blocks, 4_098, 4_096}} =
             PureV1.lower(function)

    too_many_operations =
      Enum.flat_map(0..16, fn block ->
        next_block = (block + 1) * 257
        List.duplicate(instruction(:undefined), 256) ++ [instruction(:goto, [next_block])]
      end) ++ [instruction(:return_undef)]

    function = %{function | instructions: List.to_tuple(too_many_operations), stack_size: 4_352}

    assert {:error, {:compiler_resource_limit, :lowered_instructions, 4_352, 4_096}} =
             PureV1.lower(function)
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
    assert {:ok, plan} = PureV1.plan(function)

    assert {:deopt, %Deopt{} = unspecialized} =
             Runtime.execute_plan(lease, frame, execution, plan)

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame, execution)

    assert %{deopt.frame | compiler_allow_reentry: false} == unspecialized.frame
    assert deopt.execution == unspecialized.execution
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

  test "scalarizes bounded lexical loops with direct guarded BEAM operations" do
    source = "(function(n){let s=0; for(let i=0;i<n;i++) s=s+i*2; return s})(100)"
    assert {:ok, %Program{} = program} = QuickBEAM.VM.compile(source)
    assert %Function{} = function = Enum.find(program.root.constants, &is_struct(&1, Function))
    assert {:ok, template, _count} = PureV1.prepare(function, 32)

    assert [{:function, _, :block, 7, _}] =
             Enum.filter(template.forms, &match?({:function, _, :block, 7, _}, &1))

    module = hd(Contract.pool_modules())
    assert {:ok, artifact} = Emitter.emit(key(77), module, template)
    assert {:ok, imports} = ImportPolicy.imports(artifact.binary)
    assert {:erlang, :+, 2} in imports
    assert {:erlang, :*, 2} in imports
    refute {Runtime, :execute_fast_block, 4} in imports

    local_source =
      "(function(n){let a=1,b=2,c=3; for(let i=0;i<n;i++){a=b+c+i;b=a+c;c=a+b} return c})(100)"

    assert {:ok, local_program} = QuickBEAM.VM.compile(local_source)
    local_function = Enum.find(local_program.root.constants, &is_struct(&1, Function))
    assert {:ok, local_template, _count} = PureV1.prepare(local_function, 32)
    assert Enum.any?(local_template.forms, &match?({:function, _, :block, 7, _}, &1))

    start_pool()
    assert {:ok, interpreter} = QuickBEAM.VM.measure(program, max_steps: 10_000)
    assert {:ok, compiler} = QuickBEAM.VM.measure(program, engine: :compiler, max_steps: 10_000)
    assert compiler.result == interpreter.result
    assert compiler.steps == interpreter.steps
    assert compiler.logical_memory_bytes == interpreter.logical_memory_bytes

    for limit <- [1, 7, 50, interpreter.steps - 1] do
      assert QuickBEAM.VM.eval(program, engine: :compiler, max_steps: limit) ==
               QuickBEAM.VM.eval(program, max_steps: limit)
    end
  end

  test "scalar properties and explicit calls preserve canonical boundaries" do
    start_pool()

    sources = [
      "(function(arr){let s=0;for(let i=0;i<arr.length;i++)s+=arr[i];return s})([1,2,3,4])",
      "(function(obj,n){let s=0;for(let i=0;i<n;i++)s+=obj.x;return s})({x:3},10)",
      "let hits=0;let obj={get x(){hits++;return 3}};[(function(o){let s=0;for(let i=0;i<3;i++)s+=o.x;return s})(obj),hits]",
      "(function(value){return value.x})(null)",
      "(function(fn,n){let s=0;for(let i=0;i<n;i++)s=fn(s);return s})(function(x){return x+1},10)"
    ]

    for source <- sources do
      assert {:ok, program} = QuickBEAM.VM.compile(source)
      assert {:ok, interpreted} = QuickBEAM.VM.measure(program)

      assert {:ok, compiled} =
               QuickBEAM.VM.measure(program,
                 engine: :compiler,
                 compiler_profile: :scalar_v1
               )

      assert compiled.result == interpreted.result
      assert compiled.steps == interpreted.steps
      assert compiled.logical_memory_bytes == interpreted.logical_memory_bytes

      for limit <- [1, max(interpreted.steps - 1, 1)] do
        assert QuickBEAM.VM.eval(program,
                 engine: :compiler,
                 compiler_profile: :scalar_v1,
                 max_steps: limit
               ) == QuickBEAM.VM.eval(program, max_steps: limit)
      end
    end
  end

  test "scalar call re-entry preserves stacks and deterministic resources" do
    start_pool()

    source =
      "(function(fn,n){let s=0;for(let i=0;i<n;i++)s=fn(s);return s})(function(x){return x+1},10)"

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    opts = [engine: :compiler, compiler_profile: :scalar_v1, max_steps: 10_000]
    assert {:ok, interpreted} = QuickBEAM.VM.measure(program, max_steps: 10_000)
    assert {:ok, compiled} = QuickBEAM.VM.measure(program, opts)
    assert compiled.result == interpreted.result
    assert compiled.steps == interpreted.steps
    assert compiled.logical_memory_bytes == interpreted.logical_memory_bytes
    assert compiled.compiler_counters.profile == :scalar_v1
    assert compiled.compiler_counters.generated_steps > 0
    assert compiled.compiler_counters.generated_steps < compiled.steps
    assert compiled.compiler_counters.invocation_actions > 0

    for limit <- [1, 10, div(interpreted.steps, 2), interpreted.steps - 1] do
      assert QuickBEAM.VM.eval(program, Keyword.put(opts, :max_steps, limit)) ==
               QuickBEAM.VM.eval(program, max_steps: limit)
    end
  end

  test "scalar globals preserve canonical state, errors, and resource counters" do
    start_pool()

    source =
      "var total=0;(function(n){for(let i=0;i<n;i++)total=total+i;return globalThis.total})(10)"

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    opts = [engine: :compiler, compiler_profile: :scalar_v1, max_steps: 10_000]
    assert {:ok, interpreted} = QuickBEAM.VM.measure(program, max_steps: 10_000)
    assert {:ok, compiled} = QuickBEAM.VM.measure(program, opts)
    assert compiled.result == interpreted.result
    assert compiled.steps == interpreted.steps
    assert compiled.logical_memory_bytes == interpreted.logical_memory_bytes
    assert compiled.compiler_counters.generated_steps > 100
    assert compiled.compiler_counters.interpreted_opcodes[:get_var] == nil
    assert compiled.compiler_counters.interpreted_opcodes[:put_var] == 1

    for limit <- [1, 20, div(interpreted.steps, 2), interpreted.steps - 1] do
      assert QuickBEAM.VM.eval(program, Keyword.put(opts, :max_steps, limit)) ==
               QuickBEAM.VM.eval(program, max_steps: limit)
    end

    missing = "(function(n){for(let i=0;i<n;i++)missing;return 0})(1)"
    assert {:ok, missing_program} = QuickBEAM.VM.compile(missing)
    assert {:ok, missing_interpreted} = QuickBEAM.VM.measure(missing_program)
    assert {:ok, missing_compiled} = QuickBEAM.VM.measure(missing_program, opts)
    assert missing_compiled.result == missing_interpreted.result
    assert missing_compiled.steps == missing_interpreted.steps
    assert missing_compiled.logical_memory_bytes == missing_interpreted.logical_memory_bytes
  end

  test "scalar guarded operations retain canonical nonnumeric fallback semantics" do
    source = "(function(n){let s=''; for(let i=0;i<n;i++) s=s+'x'; return s})(5)"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    start_pool()
    assert QuickBEAM.VM.eval(program, engine: :compiler) == QuickBEAM.VM.eval(program)
    assert QuickBEAM.VM.eval(program) == {:ok, "xxxxx"}
  end

  test "matches the interpreter across decoded v26 pure expressions" do
    pool = start_pool()

    for source <- ["40 + 2", "6 * 7", "10 > 3", "true ? 11 : 22", "(5 << 2) | 1"] do
      assert {:ok, %Program{root: function} = program} = QuickBEAM.VM.compile(source)
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
  end

  test "lowers decoded function arguments and locals through canonical frames" do
    source = "function calc(a, b) { let value = a + b; return value * 2 } calc"
    assert {:ok, %Program{} = program} = QuickBEAM.VM.compile(source)
    assert %Function{} = function = Enum.find(program.root.constants, &is_struct(&1, Function))
    pool = start_pool()

    assert {:ok, template} = PureV1.lower(function)
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)

    frame = Invocation.new_frame(function, function, [20, 1], :undefined, {})
    execution = %{execution(100) | atoms: program.atoms}

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame, execution)

    assert deopt.frame.pc > 0
    assert :ok = ModulePool.checkin(pool, lease)
    assert Interpreter.resume_deopt(deopt) == {:ok, 42}
  end

  test "tail-calls compiled successor blocks before deoptimizing at return" do
    function = branch_function()
    program = program(function)
    pool = start_pool()

    assert {:ok, template} = PureV1.lower(function)
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    assert {:ok, lease} = ModulePool.checkout(pool, artifact_key, template)

    assert {:deopt, %Deopt{} = deopt} =
             GeneratedModule.invoke(pool, lease, frame(function), execution(10))

    assert deopt.reason == :unsupported_opcode
    assert deopt.frame.pc == 5
    assert deopt.frame.stack == [10]
    assert deopt.execution.remaining_steps == 6
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
