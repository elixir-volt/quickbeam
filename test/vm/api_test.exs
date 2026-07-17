defmodule QuickBEAM.VM.APITest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM

  test "rejects invalid public inputs without raising" do
    assert {:error, :invalid_source} = VM.compile(:not_source)
    assert {:error, :invalid_bytecode} = VM.decode(:not_bytecode)
    assert {:error, :invalid_program} = VM.pin(:not_program)
    assert {:error, :invalid_program} = VM.eval(:not_program)
    assert {:error, :invalid_program} = VM.measure(:not_program)
    assert {:error, :invalid_pinned_program} = VM.unpin(:not_pinned)
  end

  test "validates option lists and rejects unknown options" do
    assert {:error, {:invalid_options, [:invalid]}} = VM.compile("1", [:invalid])

    assert {:error, {:unknown_option, :runtime_options}} =
             VM.compile("1", runtime_options: [])

    assert {:error, {:unknown_option, :unknown}} = VM.decode(<<>>, unknown: true)

    assert {:ok, program} = VM.compile("1")
    assert {:error, {:invalid_options, [:invalid]}} = VM.eval(program, [:invalid])
    assert {:error, {:unknown_option, :engine}} = VM.eval(program, engine: :compiler)

    assert {:error, {:unknown_option, :compiler_profile}} =
             VM.eval(program, compiler_profile: :scalar_v1)

    assert {:error, {:unknown_option, :unknown}} = VM.measure(program, unknown: true)
  end

  test "public verifier limits can only tighten built-in bounds" do
    assert {:error, {:invalid_limit, :max_instructions}} =
             VM.compile("1", max_instructions: 1_000_001)

    oversized = 16 * 1024 * 1024 + 1

    assert {:error, {:invalid_option, :max_bytecode_bytes, ^oversized}} =
             VM.compile("1", max_bytecode_bytes: oversized)
  end

  test "public measurements contain only interpreter observations" do
    assert {:ok, program} = VM.compile("1")
    assert {:ok, measurement} = VM.measure(program)
    refute Map.has_key?(measurement, :compiler_counters)
    refute Map.has_key?(measurement, :compiler_regions)
  end

  test "unpin reports stale handles through a stable error tuple" do
    assert {:ok, program} = VM.compile("1")
    assert {:ok, pinned} = VM.pin(program)
    assert :ok = VM.unpin(pinned)
    assert {:error, :pinned_program_unavailable} = VM.unpin(pinned)
  end

  test "internal identity and worker helpers are not part of the VM facade" do
    refute function_exported?(VM, :worker_spawn_options, 1)
    refute function_exported?(QuickBEAM.VM.Program, :put_pin_key, 1)
  end
end
