defmodule Mix.Tasks.Quickbeam.Vm.Fuzz do
  @shortdoc "Runs bounded QuickBEAM decoder and verifier mutation fuzzing"
  @moduledoc """
  Runs the deterministic bytecode decoder and verifier mutation corpora.

      mix quickbeam.vm.fuzz --iterations 10000 --seed 5325389

  Every mutation is evaluated twice in a heap-limited monitored process. The
  command exits unsuccessfully on a crash, timeout, nondeterministic result, or
  accepted deliberately-invalid verifier mutation.
  """

  use Mix.Task

  alias QuickBEAM.VM.Fuzz

  @switches [iterations: :integer, seed: :integer, timeout: :integer, max_heap_bytes: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {options, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    fuzz_options = [
      iterations: Keyword.get(options, :iterations, 10_000),
      seed: Keyword.get(options, :seed, 0x51424D),
      timeout: Keyword.get(options, :timeout, 100),
      max_heap_bytes: Keyword.get(options, :max_heap_bytes, 16 * 1024 * 1024)
    ]

    bytecode_corpus = compile_corpus!()

    program_corpus =
      Enum.map(bytecode_corpus, fn {name, bytecode} -> {name, decode!(bytecode)} end)

    {:ok, decoder} = Fuzz.run_bytecode(bytecode_corpus, fuzz_options)
    {:ok, verifier} = Fuzz.run_verifier(program_corpus, fuzz_options)

    print_summary(decoder)
    print_summary(verifier)

    findings = decoder.findings ++ verifier.findings

    if findings != [] do
      Enum.each(findings, &Mix.shell().error(format_finding(&1)))
      Mix.raise("VM mutation fuzzing found #{length(findings)} failure(s)")
    end
  end

  defp compile_corpus! do
    {:ok, runtime} = QuickBEAM.start(apis: false)

    try do
      Enum.map(Fuzz.default_sources(), fn {name, source} ->
        case QuickBEAM.compile(runtime, source) do
          {:ok, bytecode} -> {name, bytecode}
          {:error, reason} -> Mix.raise("failed to compile #{name}: #{inspect(reason)}")
        end
      end)
    after
      QuickBEAM.stop(runtime)
    end
  end

  defp decode!(bytecode) do
    case QuickBEAM.VM.decode(bytecode) do
      {:ok, program} -> program
      {:error, reason} -> Mix.raise("valid corpus bytecode failed decoding: #{inspect(reason)}")
    end
  end

  defp print_summary(summary) do
    Mix.shell().info(
      "#{summary.domain}: #{summary.iterations} mutations, " <>
        "outcomes=#{inspect(summary.counts)}, operations=#{inspect(summary.operation_counts)}"
    )
  end

  defp format_finding(finding) do
    mutation = finding.mutation

    "#{mutation.domain} finding corpus=#{mutation.corpus} seed=#{mutation.seed} " <>
      "iteration=#{mutation.iteration} operation=#{mutation.operation}: #{inspect(finding.outcome)}"
  end
end
