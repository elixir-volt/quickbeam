defmodule QuickBEAM.Bench.VMCompilerRegionHotspots do
  @moduledoc """
  Samples bounded dynamic instruction windows in the pinned SSR fixtures.
  """

  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Compiler.Lowering.PureV1
  alias QuickBEAM.VM.{Function, Opcodes}

  @module_slots 32

  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [output: :string])

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    {:ok, _compiler} = Compiler.start_link(capacity: @module_slots)

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
  after
    if Process.whereis(Compiler.ModulePool), do: GenServer.stop(Compiler.ModulePool)
  end

  defp analyze_fixture(fixture, profile) do
    {:ok, source} = QuickBEAM.JS.bundle_file(fixture.path, fixture.bundle_opts)
    {:ok, program} = QuickBEAM.VM.compile(source, filename: fixture.path)
    functions = program.root |> functions() |> Map.new(&{&1.id, &1})
    options = eval_options(fixture, profile)

    {:ok, _value} = QuickBEAM.VM.eval(program, options)

    {:ok, measurement} =
      QuickBEAM.VM.measure(program, Keyword.put(options, :compiler_region_probe, true))

    unless match?({:ok, _value}, measurement.result),
      do: raise("#{fixture.name} failed: #{inspect(measurement.result)}")

    probe = measurement.compiler_regions

    regions =
      Enum.map(probe.regions, fn region ->
        function = Map.fetch!(functions, region.function_id)
        support = supported_window(function, region.entry_pc, probe.window_size, profile)
        lower_bound = max(region.samples - region.error, 0)
        weighted_support = lower_bound * support.supported / max(support.instructions, 1)

        Map.merge(region, %{
          instructions: support.instructions,
          supported: support.supported,
          lower_bound: lower_bound,
          weighted_support: weighted_support
        })
      end)

    selected =
      regions
      |> Enum.sort_by(&{-&1.weighted_support, &1.function_id, &1.entry_pc})
      |> Enum.take(@module_slots)

    lower_bound_coverage =
      100 * Enum.sum(Enum.map(selected, & &1.weighted_support)) / max(probe.total_samples, 1)

    %{
      fixture: fixture.name,
      profile: profile,
      steps: measurement.steps,
      generated_steps: measurement.compiler_counters.generated_steps,
      total_samples: probe.total_samples,
      retained_regions: length(regions),
      lower_bound_coverage: Float.round(lower_bound_coverage, 1),
      regions: regions
    }
  end

  defp supported_window(function, entry_pc, window_size, profile) do
    end_pc = min(entry_pc + window_size, tuple_size(function.instructions)) - 1

    if end_pc < entry_pc do
      %{instructions: 0, supported: 0}
    else
      Enum.reduce(entry_pc..end_pc, %{instructions: 0, supported: 0}, fn pc, counts ->
        {opcode, operands} = elem(function.instructions, pc)
        {name, _size, _pops, _pushes, _format} = Opcodes.info(opcode)
        {name, operands} = Opcodes.expand_short_form(name, operands, function.arg_count)
        instruction = {pc, name, operands}

        %{
          instructions: counts.instructions + 1,
          supported:
            counts.supported +
              if(PureV1.supported_instruction?(instruction, profile), do: 1, else: 0)
        }
      end)
    end
  end

  defp functions(%Function{} = function) do
    nested =
      Enum.flat_map(function.constants, fn
        %Function{} = child -> functions(child)
        _constant -> []
      end)

    [function | nested]
  end

  defp eval_options(fixture, compiler_profile) do
    [
      engine: :compiler,
      compiler_profile: compiler_profile,
      isolation: :caller,
      profile: :ssr,
      handlers: %{"load_props" => fn [] -> props() end},
      max_steps: fixture.max_steps,
      memory_limit: fixture.memory_limit,
      timeout: 5_000
    ]
  end

  defp fixture_specs do
    [
      %{
        name: "Preact 10.29.7",
        path: "test/fixtures/vm/preact_ssr.js",
        bundle_opts: [format: :esm, minify: false],
        max_steps: 20_000_000,
        memory_limit: 64_000_000
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
        ],
        max_steps: 50_000_000,
        memory_limit: 256_000_000
      },
      %{
        name: "Svelte 5.56.4",
        path: "test/fixtures/vm/svelte_ssr.js",
        bundle_opts: [format: :esm, minify: true],
        max_steps: 20_000_000,
        memory_limit: 64_000_000
      }
    ]
  end

  defp props do
    %{
      "title" => "Region probe",
      "products" => [
        %{"id" => 1, "name" => "Product 1", "inStock" => true, "priceCents" => 1_299}
      ]
    }
  end

  defp report(results) do
    """
    # Bounded compiler dynamic region hotspots

    This opt-in diagnostic samples every 16th interpreted instruction into at
    most 64 owner-local Space-Saving heavy hitters. Windows are aligned to 64
    instruction PCs. `samples-error` is the conservative frequency lower bound;
    fixed-pool potential applies each window's statically supported ratio to the
    32 strongest lower bounds. Generated instructions are not sampled. Results
    are fixture/profile-specific and are not production telemetry or speedup
    claims.

    - Git base: `#{command("git", ["rev-parse", "--short", "HEAD"])}`
    - Working tree at measurement: #{tree_state()}
    - Generated: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
    - Elixir: #{System.version()}
    - OTP: #{System.otp_release()}
    - CPU: #{cpu_model()}
    - Sampling interval: 16 interpreted instructions
    - Heavy-hitter capacity: 64 regions
    - Fixed generated-module slots: #{@module_slots}

    | Fixture | profile | VM steps | existing generated steps | samples | retained regions | fixed-pool supported lower bound |
    |---|---|---:|---:|---:|---:|---:|
    #{Enum.map_join(results, "\n", &summary_row/1)}

    ## Leading sampled windows

    | Fixture | profile | function@pc | samples | error | lower bound | supported instructions |
    |---|---|---|---:|---:|---:|---:|
    #{Enum.map_join(results, "\n", &hotspot_rows/1)}

    The next implementation gate is positive only when a small fixed region set
    has a meaningful conservative dynamic lower bound. Otherwise region
    compilation would add artifact churn without enough warm execution.
    """
  end

  defp summary_row(result) do
    "| #{result.fixture} | `#{result.profile}` | #{result.steps} | " <>
      "#{result.generated_steps} | #{result.total_samples} | #{result.retained_regions} | " <>
      "#{result.lower_bound_coverage}% |"
  end

  defp hotspot_rows(result) do
    result.regions
    |> Enum.sort_by(&{-&1.lower_bound, -&1.samples, &1.function_id, &1.entry_pc})
    |> Enum.take(8)
    |> Enum.map_join("\n", fn region ->
      "| #{result.fixture} | `#{result.profile}` | `f#{region.function_id}@#{region.entry_pc}` | " <>
        "#{region.samples} | #{region.error} | #{region.lower_bound} | " <>
        "#{region.supported}/#{region.instructions} |"
    end)
  end

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

QuickBEAM.Bench.VMCompilerRegionHotspots.run(System.argv())
