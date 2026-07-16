defmodule QuickBEAM.VM.CompilerContractTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Compiler.{Contract, Deopt}
  alias QuickBEAM.VM.{Execution, Frame, Function, Program}

  test "uses one fixed unique module atom set" do
    modules = Contract.pool_modules()

    assert length(modules) == 32
    assert length(Enum.uniq(modules)) == 32
    assert Contract.pool_capacity() == 32
    assert hd(modules) == QuickBEAM.VM.Compiler.Slot00
    assert List.last(modules) == QuickBEAM.VM.Compiler.Slot31
  end

  test "artifact identities are deterministic binaries and do not allocate per-program atoms" do
    {program, function} = program_and_function()
    assert {:ok, namespace} = Contract.program_identity(program)
    assert byte_size(namespace) == Contract.artifact_key_bytes()
    assert {:ok, first} = Contract.artifact_key(program, function)
    assert {:ok, ^first} = Contract.artifact_key(program, function)
    assert {:ok, ^first} = Contract.artifact_key_from_identity(namespace, function)
    assert byte_size(first) == Contract.artifact_key_bytes()

    # Warm every code path before measuring the permanent atom table.
    assert {:ok, _key} = Contract.artifact_key(program, %{function | id: 0})
    atom_count = :erlang.system_info(:atom_count)

    for id <- 1..10_000 do
      assert {:ok, key} = Contract.artifact_key(program, %{function | id: id})
      assert is_binary(key)
    end

    assert :erlang.system_info(:atom_count) == atom_count
  end

  test "artifact identities cover the program fingerprint and immutable function" do
    {program, function} = program_and_function()
    assert {:ok, key} = Contract.artifact_key(program, function)

    assert {:ok, changed_program_key} =
             Contract.artifact_key(%{program | fingerprint: "other"}, function)

    assert {:ok, changed_function_key} =
             Contract.artifact_key(program, %{function | stack_size: function.stack_size + 1})

    assert {:ok, changed_source_key} =
             Contract.artifact_key(
               %{program | source_digest: :crypto.hash(:sha256, "source")},
               function
             )

    assert {:ok, changed_atoms_key} = Contract.artifact_key(%{program | atoms: {"x"}}, function)

    refute changed_program_key == key
    refute changed_function_key == key
    refute changed_source_key == key
    refute changed_atoms_key == key

    assert {:error, {:unknown_option, :unknown}} =
             Contract.artifact_key(program, function, unknown: true)

    assert {:error, {:unsupported_compiler_profile, :future}} =
             Contract.artifact_key(program, function, profile: :future)
  end

  test "deoptimization state is owner-local and points before a valid instruction" do
    {program, function} = program_and_function()
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)
    frame = frame(function)
    execution = execution(program)

    assert {:ok, %Deopt{} = deopt} =
             Deopt.new(:unsupported_opcode, artifact_key, 1, 2, frame, execution)

    assert deopt.owner == self()
    assert deopt.phase == :before_instruction
    assert :ok = Deopt.validate(deopt)

    task = Task.async(fn -> Deopt.validate(deopt) end)

    assert {:error, {:deopt_owner_mismatch, owner, validator}} = Task.await(task)
    assert owner == self()
    refute validator == self()
  end

  test "deoptimization rejects stale contracts and invalid boundaries" do
    {program, function} = program_and_function()
    assert {:ok, artifact_key} = Contract.artifact_key(program, function)

    assert {:ok, deopt} =
             Deopt.new(
               {:guard_failed, :primitive_number},
               artifact_key,
               0,
               0,
               frame(function),
               execution(program)
             )

    assert {:error, {:stale_compiler_contract, 0}} =
             Deopt.validate(%{deopt | contract_version: 0})

    bad_frame = %{deopt.frame | pc: tuple_size(function.instructions)}

    assert {:error, {:invalid_deopt_boundary, ^bad_frame}} =
             Deopt.validate(%{deopt | frame: bad_frame})

    assert {:error, {:invalid_artifact_key, <<0>>}} =
             Deopt.validate(%{deopt | artifact_key: <<0>>})
  end

  defp program_and_function do
    function = %Function{
      id: 1,
      name: "contract",
      atoms: {},
      instructions: {{:push_i32, [42]}, {:return, []}},
      stack_size: 1
    }

    program = %Program{version: 26, fingerprint: "fixture", atoms: {}, root: function}
    {program, function}
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

  defp execution(program) do
    %Execution{
      atoms: program.atoms,
      max_stack_depth: 32,
      remaining_steps: 100,
      step_limit: 100
    }
  end
end
