defmodule QuickBEAM.VM.FuzzTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Fuzz
  alias QuickBEAM.VM.Fuzz.Finding

  @seed 0x51424D
  @regression_directory Path.expand("../fixtures/vm/fuzz/regressions", __DIR__)

  setup_all do
    {:ok, runtime} = QuickBEAM.start(apis: false)

    bytecode =
      Enum.map(Fuzz.default_sources(), fn {name, source} ->
        assert {:ok, compiled} = QuickBEAM.compile(runtime, source)
        {name, compiled}
      end)

    QuickBEAM.stop(runtime)

    programs =
      Enum.map(bytecode, fn {name, compiled} ->
        assert {:ok, program} = QuickBEAM.VM.decode(compiled)
        {name, program}
      end)

    %{bytecode: bytecode, programs: programs}
  end

  test "runs thousands of deterministic bounded decoder mutations", %{bytecode: corpus} do
    assert {:ok, summary} =
             Fuzz.run_bytecode(corpus,
               seed: @seed,
               iterations: 2_000,
               timeout: 100,
               max_heap_bytes: 16 * 1024 * 1024
             )

    assert Fuzz.safe?(summary)
    assert summary.findings == []
    assert Enum.sum(Map.values(summary.counts)) == 2_000
    assert map_size(summary.operation_counts) == 13
    assert summary.counts[:truncated] > 0
    assert summary.counts[:malformed_integer] > 0
    assert summary.counts[:limit] > 0
  end

  test "rejects every deliberately invalid verifier mutation", %{programs: corpus} do
    assert {:ok, summary} =
             Fuzz.run_verifier(corpus,
               seed: @seed,
               iterations: 1_000,
               timeout: 100,
               max_heap_bytes: 16 * 1024 * 1024
             )

    assert Fuzz.safe?(summary)
    assert summary.findings == []
    assert Enum.sum(Map.values(summary.counts)) == 1_000
    assert map_size(summary.operation_counts) == 17
    refute Map.has_key?(summary.counts, :accepted_invalid_program)
    assert summary.counts[:invalid_jump] > 0
    assert summary.counts[:invalid_reference] > 0
    assert summary.counts[:stack_underflow] > 0
    assert summary.counts[:invalid_stack] > 0
  end

  test "mutation replay is independent of process random state", %{
    bytecode: corpus,
    programs: programs
  } do
    {bytecode_name, bytecode} = Enum.at(corpus, 2)
    {program_name, program} = Enum.at(programs, 3)

    :rand.seed(:exsss, {1, 2, 3})
    first_bytecode = Fuzz.bytecode_mutation(bytecode_name, bytecode, @seed, 719)
    first_program = Fuzz.program_mutation(program_name, program, @seed, 719)

    :rand.seed(:exsss, {999, 888, 777})
    assert Fuzz.bytecode_mutation(bytecode_name, bytecode, @seed, 719) == first_bytecode
    assert Fuzz.program_mutation(program_name, program, @seed, 719) == first_program
  end

  test "writes replayable regression artifacts", %{bytecode: [{name, bytecode} | _rest]} do
    directory =
      Path.join(
        System.tmp_dir!(),
        "quickbeam-vm-regression-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(directory) end)

    mutation = Fuzz.bytecode_mutation(name, bytecode, @seed, 17)
    finding = %Finding{mutation: mutation, outcome: {:crash, :synthetic_test_reason}}

    assert {:ok, binary_path} = Fuzz.persist(finding, directory)
    assert File.read!(binary_path) == mutation.value

    metadata_path = Path.rootname(binary_path) <> ".txt"
    metadata = File.read!(metadata_path)
    assert metadata =~ "seed: #{@seed}"
    assert metadata =~ "iteration: 17"
    assert metadata =~ "sha256:"
  end

  test "persisted minimized regressions remain bounded typed rejections" do
    for path <- Path.wildcard(Path.join(@regression_directory, "*.bin")) do
      bytecode = File.read!(path)

      assert {:ok, {:rejected, classification, _reason}} =
               Fuzz.probe_bytecode(bytecode,
                 timeout: 100,
                 max_heap_bytes: 16 * 1024 * 1024
               )

      assert is_atom(classification)
    end
  end
end
