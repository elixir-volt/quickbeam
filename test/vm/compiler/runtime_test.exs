defmodule QuickBEAM.VM.Compiler.RuntimeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Compiler.Deopt
  alias QuickBEAM.VM.Compiler.Pool.Lease
  alias QuickBEAM.VM.Compiler.Runtime
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.State

  test "charges guaranteed blocks exactly and deoptimizes before a partial block" do
    frame = frame()
    execution = execution(5)
    lease = lease()

    assert {:ok, ^frame, charged} = Runtime.charge_block(lease, frame, execution, 3)
    assert charged.remaining_steps == 2

    assert {:deopt, %Deopt{} = deopt} = Runtime.charge_block(lease, frame, charged, 3)
    assert deopt.reason == :step_boundary
    assert deopt.frame == frame
    assert deopt.execution.remaining_steps == 2
    assert deopt.phase == :before_instruction
  end

  test "rejects execution with another process's lease" do
    owner_lease = lease()
    frame = frame()
    execution = execution(5)

    task =
      Task.async(fn ->
        {
          Runtime.charge_block(owner_lease, frame, execution, 1),
          Runtime.deopt(:unsupported_opcode, owner_lease, frame, execution)
        }
      end)

    assert {
             {:error, :compiler_lease_owner_mismatch},
             {:error, :compiler_lease_owner_mismatch}
           } = Task.await(task)
  end

  test "reports an existing logical memory failure before charging steps" do
    frame = frame()
    execution = %{execution(5) | memory_exceeded: true, memory_limit: 64}

    assert {:error, {:limit_exceeded, :memory_bytes, 64}, ^execution} =
             Runtime.charge_block(lease(), frame, execution, 1)
  end

  test "delegates stack and value instructions to canonical opcode semantics" do
    execution = execution(10)
    frame = frame()

    assert {:ok, pushed, ^execution} = Runtime.execute_stack(:push_i32, [40], frame, execution)
    assert pushed.pc == 1
    assert pushed.stack == [40]

    pushed = %{pushed | pc: 0}
    assert {:ok, pushed, ^execution} = Runtime.execute_stack(:push_i32, [2], pushed, execution)
    assert pushed.stack == [2, 40]

    pushed = %{pushed | pc: 0}
    assert {:ok, added, ^execution} = Runtime.execute_value(:add, [], pushed, execution)
    assert added.pc == 1
    assert added.stack == [42]
  end

  test "delegates local reads and branches without bypassing canonical frame state" do
    execution = execution(10)
    frame = %{frame() | locals: {42}}

    assert {:ok, local, ^execution} = Runtime.execute_local(:get_loc, [0], frame, execution)
    assert local.stack == [42]
    assert local.pc == 1

    branch = %{frame | stack: [false]}
    assert {:ok, jumped, ^execution} = Runtime.execute_branch(:if_false, [7], branch, execution)
    assert jumped.pc == 7
    assert jumped.stack == []
  end

  test "exposes only the declared primitive ABI operations" do
    assert Runtime.version() == Contract.runtime_abi_version()
    assert Runtime.truthy?("value")
    assert Runtime.unary(:inc, 41) == 42
    assert Runtime.binary(:strict_eq, 42, 42.0)

    assert {:error, {:unsupported_compiler_local_operation, :rest, [0]}} =
             Runtime.execute_local(:rest, [0], frame(), execution(10))
  end

  defp frame do
    function = %Function{
      id: 0,
      atoms: {},
      instructions: {{0, []}, {0, []}, {0, []}, {0, []}, {0, []}, {0, []}, {0, []}, {0, []}}
    }

    %Frame{
      function: function,
      callable: function,
      locals: {},
      args: {},
      this: :undefined
    }
  end

  defp execution(steps) do
    %State{
      atoms: {},
      max_stack_depth: 32,
      remaining_steps: steps,
      step_limit: steps
    }
  end

  defp lease do
    %Lease{
      pool: self(),
      module: hd(Contract.pool_modules()),
      key: :crypto.hash(:sha256, "runtime-test"),
      epoch: 1,
      generation: 1,
      token: make_ref(),
      owner: self()
    }
  end
end
