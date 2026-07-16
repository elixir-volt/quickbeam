defmodule QuickBEAM.Bench.VMCompilerRegionProbe do
  @moduledoc """
  Computes a static upper bound for bounded one-block compiler regions.
  """

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.Lowering.PureV1
  alias QuickBEAM.VM.Function

  @max_region_operations 64
  @module_slots 32
  @preflight_operations [:get_array_el, :get_field, :get_field2, :get_length, :get_var]
  @invocation_operations [:call, :call_method]

  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [output: :string])

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    results =
      for fixture <- fixture_specs(), profile <- [:pure_v1, :scalar_v1] do
        analyze_fixture(fixture, profile)
      end

    report = report(results)
    IO.write(report)

    if output = opts[:output] do
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, report)
    end
  end

  defp analyze_fixture(fixture, profile) do
    {:ok, source} = QuickBEAM.JS.bundle_file(fixture.path, fixture.bundle_opts)
    {:ok, program} = QuickBEAM.VM.compile(source, filename: fixture.path)
    functions = functions(program.root)

    regions =
      Enum.flat_map(functions, fn function ->
        {:ok, blocks} = CFG.analyze(function)

        Enum.flat_map(blocks, fn block ->
          block.instructions
          |> split_regions(profile, [], [])
          |> Enum.map(fn instructions ->
            %{
              function_id: function.id,
              entry_pc: instructions |> hd() |> elem(0),
              operations: length(instructions)
            }
          end)
        end)
      end)

    instruction_count = Enum.sum(Enum.map(functions, &tuple_size(&1.instructions)))
    region_operations = Enum.sum(Enum.map(regions, & &1.operations))

    slot_operations =
      regions
      |> Enum.sort_by(&{-&1.operations, &1.function_id, &1.entry_pc})
      |> Enum.take(@module_slots)
      |> Enum.reduce(0, &(&1.operations + &2))

    %{
      fixture: fixture.name,
      profile: profile,
      functions: length(functions),
      instructions: instruction_count,
      region_functions: regions |> Enum.map(& &1.function_id) |> Enum.uniq() |> length(),
      regions: length(regions),
      region_operations: region_operations,
      region_coverage: percentage(region_operations, instruction_count),
      slot_operations: slot_operations,
      slot_coverage: percentage(slot_operations, instruction_count)
    }
  end

  defp split_regions([], _profile, [], regions), do: Enum.reverse(regions)

  defp split_regions([], _profile, current, regions),
    do: Enum.reverse([Enum.reverse(current) | regions])

  defp split_regions([instruction | instructions], profile, current, regions) do
    {_pc, name, _operands} = instruction

    cond do
      not PureV1.supported_instruction?(instruction, profile) ->
        regions = flush(current, regions)
        split_regions(instructions, profile, [], regions)

      name in @preflight_operations ->
        regions = [[instruction] | flush(current, regions)]
        split_regions(instructions, profile, [], regions)

      name in @invocation_operations ->
        current = [instruction | current]
        split_regions(instructions, profile, [], [Enum.reverse(current) | regions])

      length(current) + 1 == @max_region_operations ->
        current = [instruction | current]
        split_regions(instructions, profile, [], [Enum.reverse(current) | regions])

      true ->
        split_regions(instructions, profile, [instruction | current], regions)
    end
  end

  defp flush([], regions), do: regions
  defp flush(current, regions), do: [Enum.reverse(current) | regions]

  defp functions(%Function{} = function) do
    nested =
      Enum.flat_map(function.constants, fn
        %Function{} = child -> functions(child)
        _constant -> []
      end)

    [function | nested]
  end

  defp fixture_specs do
    [
      %{
        name: "Preact 10.29.7",
        path: "test/fixtures/vm/preact_ssr.js",
        bundle_opts: [format: :esm, minify: false]
      },
      %{
        name: "Vue 3.5.39",
        path: "test/fixtures/vm/vue_ssr.js",
        bundle_opts: [
          format: :esm,
          minify: true,
          define: %{
            "__VUE_OPTIONS_API__" => "true",
            "__VUE_PROD_DEVTOOLS__" => "false",
            "__VUE_PROD_HYDRATION_MISMATCH_DETAILS__" => "false",
            "process.env.NODE_ENV" => ~s("production")
          }
        ]
      },
      %{
        name: "Svelte 5.56.4",
        path: "test/fixtures/vm/svelte_ssr.js",
        bundle_opts: [format: :esm, minify: true]
      }
    ]
  end

  defp report(results) do
    """
    # Bounded compiler region coverage probe

    This static probe partitions each verified basic block into independently
    compilable regions of at most #{@max_region_operations} operations. Property
    and strict-global reads remain isolated preflight regions, calls terminate a
    region, and unsupported instructions are excluded. The fixed module-pool
    estimate retains only the #{@module_slots} largest regions. These figures are
    an instruction-inventory bound, not dynamic execution coverage or a speedup
    claim.

    - Git base: `#{command("git", ["rev-parse", "--short", "HEAD"])}`
    - Working tree at measurement: #{tree_state()}
    - Generated: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
    - Elixir: #{System.version()}
    - OTP: #{System.otp_release()}
    - CPU: #{cpu_model()}
    - Maximum operations per region: #{@max_region_operations}
    - Fixed generated-module slots: #{@module_slots}

    | Fixture | profile | functions | instructions | region functions | bounded regions | regionizable instructions | static region coverage | largest 32 instructions | fixed-pool static coverage |
    |---|---|---:|---:|---:|---:|---:|---:|---:|---:|
    #{Enum.map_join(results, "\n", &row/1)}

    A region tier is useful only if dynamic hot-region measurements show that a
    small fixed set is executed repeatedly. Static coverage alone cannot justify
    compiling every listed region or exceeding the existing module and decision
    bounds.
    """
  end

  defp row(result) do
    "| #{result.fixture} | `#{result.profile}` | #{result.functions} | " <>
      "#{result.instructions} | #{result.region_functions} | #{result.regions} | " <>
      "#{result.region_operations} | #{result.region_coverage}% | " <>
      "#{result.slot_operations} | #{result.slot_coverage}% |"
  end

  defp percentage(value, total), do: Float.round(100 * value / max(total, 1), 1)

  defp tree_state do
    case command("git", ["status", "--porcelain"]) do
      "" -> "clean"
      _changes -> "modified"
    end
  end

  defp command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> "unknown"
    end
  end

  defp cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value("unknown", fn line ->
          case String.split(line, ":", parts: 2) do
            [key, model] -> if(String.trim(key) == "model name", do: String.trim(model))
            _line -> nil
          end
        end)

      {:error, _reason} ->
        command("sysctl", ["-n", "machdep.cpu.brand_string"])
    end
  end
end

QuickBEAM.Bench.VMCompilerRegionProbe.run(System.argv())
