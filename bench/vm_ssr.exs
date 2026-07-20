defmodule QuickBEAM.Bench.VMSSR do
  @moduledoc """
  Reproducible fixture-specific measurements for the isolated BEAM VM SSR path.
  """

  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Runtime.Engine

  @default_samples 30
  @default_warmup 3
  @default_concurrency [1, 4, 8]

  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          engine: :string,
          compiler_profile: :string,
          compiler_regions: :boolean,
          pinned_programs: :boolean,
          samples: :integer,
          warmup: :integer,
          concurrency: :string,
          output: :string
        ]
      )

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    engine = engine!(Keyword.get(opts, :engine, "interpreter"))
    compiler_profile = compiler_profile!(Keyword.get(opts, :compiler_profile, "pure_v1"))
    compiler_regions = Keyword.get(opts, :compiler_regions, false)
    pinned_programs = Keyword.get(opts, :pinned_programs, false)
    maybe_start_compiler!(engine)
    samples = positive!(Keyword.get(opts, :samples, @default_samples), :samples)
    warmup = non_negative!(Keyword.get(opts, :warmup, @default_warmup), :warmup)

    concurrency =
      concurrency!(Keyword.get(opts, :concurrency, Enum.join(@default_concurrency, ",")))

    fixtures =
      Enum.map(
        fixture_specs(),
        &compile_fixture!(&1, engine, compiler_profile, compiler_regions, pinned_programs)
      )

    results =
      Enum.map(fixtures, fn fixture ->
        warm(fixture, warmup)

        %{
          name: fixture.name,
          sequential: sequential(fixture, samples),
          concurrency: Enum.map(concurrency, &concurrent(fixture, samples, &1)),
          limits: limits(fixture)
        }
      end)

    isolation = isolation_probe(hd(fixtures))

    report =
      markdown_report(
        engine,
        compiler_profile,
        compiler_regions,
        pinned_programs,
        results,
        isolation,
        samples,
        warmup,
        concurrency
      )

    IO.write(report)

    if output = opts[:output] do
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, report)
    end
  end

  defp fixture_specs do
    [
      %{
        name: "Preact 10.29.7",
        fixture: "test/fixtures/vm/preact_ssr.js",
        bundle_opts: [format: :esm, minify: false],
        eval_opts: [
          profile: :ssr,
          max_steps: 20_000_000,
          memory_limit: 64_000_000,
          timeout: 2_000
        ]
      },
      %{
        name: "Vue 3.5.39",
        fixture: "test/fixtures/vm/vue_ssr.js",
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
        eval_opts: [
          profile: :ssr,
          max_steps: 50_000_000,
          memory_limit: 256_000_000,
          timeout: 5_000
        ]
      },
      %{
        name: "Svelte 5.56.4",
        fixture: "test/fixtures/vm/svelte_ssr.js",
        bundle_opts: [format: :esm, minify: true],
        eval_opts: [
          profile: :ssr,
          max_steps: 20_000_000,
          memory_limit: 64_000_000,
          timeout: 5_000
        ]
      }
    ]
  end

  defp compile_fixture!(spec, engine, compiler_profile, compiler_regions, pinned_programs) do
    {:ok, source} = QuickBEAM.JS.bundle_file(spec.fixture, spec.bundle_opts)
    {:ok, decoded_program} = QuickBEAM.VM.compile(source, filename: spec.fixture)

    program =
      if pinned_programs do
        {:ok, pinned_program} = QuickBEAM.VM.pin(decoded_program)
        pinned_program
      else
        decoded_program
      end

    eval_opts =
      spec.eval_opts
      |> Keyword.put(:engine, engine)
      |> Keyword.put(:compiler_profile, compiler_profile)
      |> Keyword.put(:compiler_regions, compiler_regions)

    spec
    |> Map.put(:program, program)
    |> Map.put(:eval_opts, eval_opts)
  end

  defp warm(_fixture, 0), do: :ok

  defp warm(fixture, count) do
    Enum.each(1..count, fn _iteration ->
      measurement = measure!(fixture, 1)
      ensure_success!(measurement)
    end)
  end

  defp sequential(fixture, samples) do
    measurements =
      Enum.map(1..samples, fn _iteration ->
        measurement = measure!(fixture, 1)
        ensure_success!(measurement)
        measurement
      end)

    %{
      wall: summarize(measurements, & &1.wall_time_us),
      process_memory: summarize(measurements, & &1.process_memory_bytes),
      reductions: summarize(measurements, & &1.reductions),
      steps: stable_value!(measurements, & &1.steps, :steps),
      logical_memory: stable_value!(measurements, & &1.logical_memory_bytes, :logical_memory),
      compiler_counters: summarize_counters(measurements)
    }
  end

  defp concurrent(fixture, samples, concurrency) do
    total = max(samples, concurrency * 3)
    started = System.monotonic_time()

    measurements =
      1..total
      |> Task.async_stream(
        fn _iteration -> measure!(fixture, 1) end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: Keyword.fetch!(fixture.eval_opts, :timeout) + 2_000
      )
      |> Enum.map(fn {:ok, measurement} ->
        ensure_success!(measurement)
        measurement
      end)

    elapsed = System.monotonic_time() - started
    elapsed_us = System.convert_time_unit(elapsed, :native, :microsecond)

    %{
      level: concurrency,
      renders: total,
      throughput: total * 1_000_000 / max(elapsed_us, 1),
      wall: summarize(measurements, & &1.wall_time_us)
    }
  end

  defp isolation_probe(fixture) do
    :erlang.garbage_collect()
    owner_memory_before = process_memory(self())
    process_count_before = :erlang.system_info(:process_count)
    started = System.monotonic_time()

    successful =
      1..100
      |> Task.async_stream(
        fn id ->
          measurement = measure!(fixture, id)

          case measurement.result do
            {:ok, html} when is_binary(html) ->
              String.contains?(html, ~s(data-id="#{id}"))

            _result ->
              false
          end
        end,
        max_concurrency: 100,
        ordered: false,
        timeout: Keyword.fetch!(fixture.eval_opts, :timeout) + 5_000
      )
      |> Enum.count(&match?({:ok, true}, &1))

    elapsed = System.monotonic_time() - started
    :erlang.garbage_collect()
    Process.sleep(20)
    :erlang.garbage_collect()

    %{
      successful: successful,
      throughput:
        100 * 1_000_000 / max(System.convert_time_unit(elapsed, :native, :microsecond), 1),
      owner_memory_delta: process_memory(self()) - owner_memory_before,
      process_count_delta: :erlang.system_info(:process_count) - process_count_before
    }
  end

  defp limits(fixture) do
    baseline = measure!(fixture, 1, handler_delay: 0)
    ensure_success!(baseline)

    step_limit = max(baseline.steps - 1, 1)
    step_measurement = measure!(fixture, 1, handler_delay: 0, max_steps: step_limit)

    memory_limit = max(div(baseline.logical_memory_bytes, 2), 1_024)
    memory_measurement = measure!(fixture, 1, handler_delay: 0, memory_limit: memory_limit)

    timeout = timeout_and_cancellation(fixture)

    %{
      step_limit: step_limit,
      step_result: result_label(step_measurement.result),
      memory_limit: memory_limit,
      memory_result: result_label(memory_measurement.result),
      timeout_ms: timeout.timeout_ms,
      timeout_wall_us: timeout.measurement.wall_time_us,
      timeout_result: result_label(timeout.measurement.result),
      cancellation_us: timeout.cancellation_us
    }
  end

  defp timeout_and_cancellation(fixture) do
    parent = self()
    timeout_ms = 200

    handler = fn [] ->
      send(parent, {:vm_ssr_handler_started, self()})
      Process.sleep(:infinity)
    end

    opts =
      fixture.eval_opts
      |> Keyword.put(:handlers, %{"load_props" => handler})
      |> Keyword.put(:timeout, timeout_ms)

    {:ok, measurement} = Engine.measure(fixture.program, opts)

    handler_pid =
      receive do
        {:vm_ssr_handler_started, pid} -> pid
      after
        timeout_ms + 1_000 -> raise "#{fixture.name} did not start its asynchronous handler"
      end

    started = System.monotonic_time()
    monitor = Process.monitor(handler_pid)

    receive do
      {:DOWN, ^monitor, :process, ^handler_pid, _reason} -> :ok
    after
      1_000 -> raise "#{fixture.name} did not cancel its asynchronous handler"
    end

    elapsed = System.monotonic_time() - started

    %{
      timeout_ms: timeout_ms,
      measurement: measurement,
      cancellation_us: System.convert_time_unit(elapsed, :native, :microsecond)
    }
  end

  defp measure!(fixture, id, overrides \\ []) do
    delay = Keyword.get(overrides, :handler_delay, 5)
    props = props("Catalog #{id}", id)

    handler = fn [] ->
      if delay > 0, do: Process.sleep(delay)
      props
    end

    eval_opts =
      fixture.eval_opts
      |> Keyword.merge(Keyword.drop(overrides, [:handler_delay]))
      |> Keyword.put(:handlers, %{"load_props" => handler})

    {:ok, measurement} = Engine.measure(fixture.program, eval_opts)
    measurement
  end

  defp ensure_success!(%{result: {:ok, _value}}), do: :ok

  defp ensure_success!(measurement),
    do: raise("SSR measurement failed: #{inspect(measurement.result)}")

  defp stable_value!(measurements, getter, label) do
    values = measurements |> Enum.map(getter) |> Enum.uniq()

    case values do
      [value] -> value
      _values -> raise "#{label} was not deterministic: #{inspect(values)}"
    end
  end

  defp summarize_counters(measurements) do
    counters = measurements |> Enum.map(& &1.compiler_counters) |> Enum.reject(&is_nil/1)

    case counters do
      [] ->
        nil

      counters ->
        counters
        |> hd()
        |> Map.keys()
        |> Enum.reject(&(&1 in [:deopt_opcodes, :interpreted_opcodes, :profile]))
        |> Map.new(fn key ->
          values = counters |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()
          {key, percentile(values, 0.50)}
        end)
        |> Map.put(:deopt_opcodes, summarize_opcode_counts(counters, :deopt_opcodes))
        |> Map.put(:interpreted_opcodes, summarize_opcode_counts(counters, :interpreted_opcodes))
        |> Map.put(:profile, stable_value!(counters, & &1.profile, :compiler_profile))
    end
  end

  defp summarize_opcode_counts(counters, field) do
    names = counters |> Enum.flat_map(&Map.keys(&1[field])) |> Enum.uniq()

    Map.new(names, fn name ->
      values = counters |> Enum.map(&Map.get(&1[field], name, 0)) |> Enum.sort()
      {name, percentile(values, 0.50)}
    end)
  end

  defp summarize(measurements, getter) do
    values = measurements |> Enum.map(getter) |> Enum.reject(&is_nil/1) |> Enum.sort()

    %{
      median: percentile(values, 0.50),
      p95: percentile(values, 0.95),
      min: hd(values),
      max: List.last(values)
    }
  end

  defp percentile(values, fraction) do
    index = (fraction * (length(values) - 1)) |> Float.ceil() |> trunc()
    Enum.at(values, index)
  end

  defp result_label({:error, {:limit_exceeded, kind, _limit}}), do: "limit:#{kind}"
  defp result_label({:error, reason}), do: "error:#{inspect(reason)}"
  defp result_label({:ok, _value}), do: "ok"

  defp markdown_report(
         engine,
         compiler_profile,
         compiler_regions,
         pinned_programs,
         results,
         isolation,
         samples,
         warmup,
         concurrency
       ) do
    metadata = metadata()

    scheduler_report =
      case {engine, compiler_profile} do
        {:compiler, :scalar_v1} -> "beam-compiler-scalar-scheduler-measurements.md"
        {:compiler, _profile} -> "beam-compiler-scheduler-measurements.md"
        {:interpreter, _profile} -> "beam-scheduler-measurements.md"
      end

    title =
      case {engine, compiler_profile, compiler_regions} do
        {:compiler, _profile, true} -> "Bounded region compiler SSR measurements"
        {:compiler, :scalar_v1, false} -> "BEAM scalar compiler SSR measurements"
        {:compiler, _profile, false} -> "BEAM compiler SSR measurements"
        {:interpreter, _profile, _regions} -> "BEAM VM SSR measurements"
      end

    scheduler_note =
      if compiler_regions do
        "The region experiment has no scheduler-gate claim because it fails the SSR latency gate."
      else
        "The single-scheduler fairness and timeout gate is published separately in " <>
          "[`#{scheduler_report}`](#{scheduler_report})."
      end

    """
    # #{title}

    These results cover only the pinned, non-streaming fixtures listed below. They
    are not browser, DOM, or general framework compatibility claims. Each render
    performs one asynchronous `Beam.call` with a fixed 5 ms handler delay.
    #{scheduler_note}

    ## Environment

    - Engine: #{engine}
    - Compiler profile: #{compiler_profile}
    - Compiler regions: #{compiler_regions}
    - Pinned program handles: #{pinned_programs}
    - Git base: `#{metadata.git}`
    - Working tree at measurement: #{metadata.tree_state}
    - Generated: #{metadata.generated}
    - Elixir: #{metadata.elixir}
    - OTP: #{metadata.otp}
    - ERTS: #{metadata.erts}
    - OS: #{metadata.os}
    - Architecture: #{metadata.architecture}
    - CPU: #{metadata.cpu}
    - Logical schedulers: #{metadata.schedulers}
    - Mix environment: `#{metadata.mix_env}`
    - Samples per fixture: #{samples} after #{warmup} warmups
    - Concurrency levels: #{Enum.join(concurrency, ", ")}

    ## Sequential isolated renders

    | Fixture | wall median | wall p95 | VM steps | logical memory | endpoint process memory | reductions median |
    |---|---:|---:|---:|---:|---:|---:|
    #{Enum.map_join(results, "\n", &sequential_row/1)}

    `VM steps` and `logical memory` are deterministic counters. Endpoint process
    memory and reductions are observed once after result conversion; they are not
    sampled peaks. Wall time includes process startup, the 5 ms host wait,
    rendering, conversion, and reply delivery.

    #{compiler_counter_report(engine, results)}
    ## Concurrent isolated renders

    | Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
    |---|---:|---:|---:|---:|---:|
    #{Enum.map_join(results, "\n", &concurrency_rows/1)}

    ## 100-render isolation and reclamation probe

    The Preact fixture was rendered 100 times concurrently with unique request
    data and one shared immutable program.

    | successful isolated renders | throughput | caller memory delta after GC | process-count delta |
    |---:|---:|---:|---:|
    | #{isolation.successful}/100 | #{Float.round(isolation.throughput, 1)} renders/s | #{signed_bytes(isolation.owner_memory_delta)} | #{signed_integer(isolation.process_count_delta)} |

    Request-specific IDs were checked in every result. Memory and process deltas
    are endpoint observations after explicit caller GC, not operating-system RSS
    measurements.

    ## Resource-limit and cancellation checks

    | Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
    |---|---:|---:|---:|---:|---:|
    #{Enum.map_join(results, "\n", &limits_row/1)}

    Memory rejection uses half the fixture's successful logical allocation.
    Timeout uses a non-returning asynchronous handler and verifies that its BEAM
    process terminates. Cancellation time is measured from `measure/2` returning
    to observation of the handler's `:DOWN` message.
    """
  end

  defp compiler_counter_report(:interpreter, _results), do: ""

  defp compiler_counter_report(:compiler, results) do
    """
    ## Compiler execution counters

    These fixed-key counters are captured from the evaluation owner. Generated
    steps, entries, deoptimizations, invocation actions, and re-entries describe
    execution; compile/cache/skip fields remain module-pool lifecycle observations.

    | Fixture | frame attempts | skipped frames | decisions C/H/S | generated steps | step coverage | entries | deopts | invocation actions | re-entries | leading deopt opcodes | hot interpreted opcodes |
    |---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
    #{Enum.map_join(results, "\n", &compiler_counter_row/1)}

    """
  end

  defp compiler_counter_row(result) do
    counters = result.sequential.compiler_counters
    coverage = 100 * counters.generated_steps / max(result.sequential.steps, 1)

    deopt_opcodes = format_opcode_counts(counters.deopt_opcodes)
    interpreted_opcodes = format_opcode_counts(counters.interpreted_opcodes)

    decisions =
      "#{counters.compiled_functions}/#{counters.cached_functions}/#{counters.skipped_functions}"

    "| #{result.name} | #{integer(counters.frame_attempts)} | " <>
      "#{integer(counters.skipped_frames)} | #{decisions} | " <>
      "#{integer(counters.generated_steps)} | " <>
      "#{Float.round(coverage, 1)}% | #{integer(counters.generated_entries)} | " <>
      "#{integer(counters.deoptimizations)} | " <>
      "#{integer(counters.invocation_actions)} | #{integer(counters.reentries)} | " <>
      "#{deopt_opcodes} | #{interpreted_opcodes} |"
  end

  defp format_opcode_counts(counts) do
    counts
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> Enum.take(8)
    |> Enum.map_join(", ", fn {name, count} -> "`#{name}`=#{count}" end)
  end

  defp sequential_row(result) do
    sequential = result.sequential

    "| #{result.name} | #{duration(sequential.wall.median)} | #{duration(sequential.wall.p95)} | " <>
      "#{integer(sequential.steps)} | #{bytes(sequential.logical_memory)} | " <>
      "#{bytes(sequential.process_memory.median)} | #{integer(sequential.reductions.median)} |"
  end

  defp concurrency_rows(result) do
    Enum.map_join(result.concurrency, "\n", fn measurement ->
      "| #{result.name} | #{measurement.level} | #{measurement.renders} | " <>
        "#{Float.round(measurement.throughput, 1)} renders/s | " <>
        "#{duration(measurement.wall.median)} | #{duration(measurement.wall.p95)} |"
    end)
  end

  defp limits_row(result) do
    limits = result.limits

    "| #{result.name} | #{limits.step_result} at #{integer(limits.step_limit)} | " <>
      "#{limits.memory_result} at #{bytes(limits.memory_limit)} | " <>
      "#{limits.timeout_result} at #{limits.timeout_ms} ms | " <>
      "#{duration(limits.timeout_wall_us)} | #{duration(limits.cancellation_us)} |"
  end

  defp metadata do
    %{
      git: command("git", ["rev-parse", "--short", "HEAD"]),
      tree_state: tree_state(),
      generated: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      elixir: System.version(),
      otp: System.otp_release(),
      erts: :erlang.system_info(:version) |> to_string(),
      os: command("uname", ["-sr"]),
      architecture: :erlang.system_info(:system_architecture) |> to_string(),
      cpu: cpu_model(),
      schedulers: System.schedulers_online(),
      mix_env: Mix.env()
    }
  end

  defp cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value("unknown", &cpu_model_line/1)

      {:error, _reason} ->
        command("sysctl", ["-n", "machdep.cpu.brand_string"])
    end
  end

  defp cpu_model_line(line) do
    case String.split(line, ":", parts: 2) do
      [key, model] -> if(String.trim(key) == "model name", do: String.trim(model))
      _line -> nil
    end
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

  defp duration(microseconds) when microseconds >= 1_000,
    do: "#{Float.round(microseconds / 1_000, 2)} ms"

  defp duration(microseconds), do: "#{microseconds} µs"

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end

  defp signed_bytes(value) when value < 0, do: "-#{bytes(abs(value))}"
  defp signed_bytes(value), do: "+#{bytes(value)}"

  defp signed_integer(value) when value > 0, do: "+#{value}"
  defp signed_integer(value), do: Integer.to_string(value)

  defp bytes(value) when value >= 1024 * 1024,
    do: "#{Float.round(value / (1024 * 1024), 2)} MiB"

  defp bytes(value) when value >= 1024, do: "#{Float.round(value / 1024, 1)} KiB"
  defp bytes(value), do: "#{value} B"

  defp integer(value), do: Integer.to_string(value)

  defp engine!("interpreter"), do: :interpreter
  defp engine!("compiler"), do: :compiler

  defp engine!(engine),
    do: raise(ArgumentError, "engine must be interpreter or compiler, got: #{inspect(engine)}")

  defp compiler_profile!("pure_v1"), do: :pure_v1
  defp compiler_profile!("scalar_v1"), do: :scalar_v1

  defp compiler_profile!(profile) do
    raise ArgumentError,
          "compiler profile must be pure_v1 or scalar_v1, got: #{inspect(profile)}"
  end

  defp maybe_start_compiler!(:interpreter), do: :ok

  defp maybe_start_compiler!(:compiler) do
    case Compiler.start_link(capacity: 32) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "compiler start failed: #{inspect(reason)}"
    end
  end

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive!(value, name),
    do: raise(ArgumentError, "#{name} must be positive, got: #{inspect(value)}")

  defp non_negative!(value, _name) when is_integer(value) and value >= 0, do: value

  defp non_negative!(value, name),
    do: raise(ArgumentError, "#{name} must be non-negative, got: #{inspect(value)}")

  defp concurrency!(value) do
    levels =
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn level ->
        case Integer.parse(level) do
          {integer, ""} when integer > 0 -> integer
          _ -> raise ArgumentError, "invalid concurrency level: #{inspect(level)}"
        end
      end)
      |> Enum.uniq()

    if levels == [], do: raise(ArgumentError, "at least one concurrency level is required")
    levels
  end

  defp props(title, id) do
    %{
      "title" => title,
      "products" => [
        %{
          "id" => id,
          "name" => "Product #{id}",
          "inStock" => rem(id, 2) == 1,
          "priceCents" => 1_299 + (id - 1) * 100
        }
      ]
    }
  end
end

QuickBEAM.Bench.VMSSR.run(System.argv())
