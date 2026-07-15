defmodule QuickBEAM.Bench.VMSchedulerProbe do
  @moduledoc "Single-scheduler fairness and timeout probe for the BEAM VM."

  alias QuickBEAM.VM.Compiler

  @fixture "test/fixtures/vm/vue_ssr.js"
  @bundle_opts [
    format: :esm,
    minify: true,
    define: %{
      "__VUE_OPTIONS_API__" => "true",
      "__VUE_PROD_DEVTOOLS__" => "false",
      "__VUE_PROD_HYDRATION_MISMATCH_DETAILS__" => "false",
      "process.env.NODE_ENV" => ~s("production")
    }
  ]
  @max_ticker_gap_us 75_000
  @max_timeout_wall_us 60_000

  @eval_opts [
    profile: :ssr,
    max_steps: 50_000_000,
    memory_limit: 512_000_000,
    timeout: 60_000
  ]

  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [engine: :string, samples: :integer, output: :string]
      )

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    if System.schedulers_online() != 1 do
      raise "run with ERL_FLAGS='+S 1:1'; got #{System.schedulers_online()} online schedulers"
    end

    samples = positive!(Keyword.get(opts, :samples, 10), :samples)
    engine = engine!(Keyword.get(opts, :engine, "interpreter"))
    maybe_start_compiler!(engine)
    fixture = compile_fixture!()

    Enum.each(1..2, fn _iteration -> render!(fixture, engine) end)

    render_observations =
      Enum.map(1..samples, fn _iteration ->
        observe_ticker(fn -> render!(fixture, engine) end)
      end)

    render_wall = render_observations |> Enum.map(& &1.wall_time_us) |> Enum.sort()
    baseline_ms = max(round(percentile(render_wall, 0.50) / 1_000), 1)

    baseline_observations =
      Enum.map(1..samples, fn _iteration ->
        observe_ticker(fn -> Process.sleep(baseline_ms) end)
      end)

    timeout_program = compile_timeout_program!()

    timeout_wall =
      Enum.map(1..samples, fn _iteration ->
        {:ok, measurement} =
          QuickBEAM.VM.measure(timeout_program,
            engine: engine,
            max_steps: 1_000_000_000,
            timeout: 50
          )

        unless measurement.result == {:error, {:limit_exceeded, :timeout, 50}},
          do: raise("unexpected timeout result: #{inspect(measurement.result)}")

        measurement.wall_time_us
      end)

    render_summary = summarize_observations(render_observations)
    baseline_summary = summarize_observations(baseline_observations)
    timeout_summary = summarize(timeout_wall)
    enforce_gates!(render_summary, timeout_summary)

    report =
      report(engine, samples, baseline_ms, render_summary, baseline_summary, timeout_summary)

    IO.write(report)

    if output = opts[:output] do
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, report)
    end
  end

  defp compile_fixture! do
    {:ok, source} = QuickBEAM.JS.bundle_file(@fixture, @bundle_opts)
    {:ok, program} = QuickBEAM.VM.compile(source, filename: @fixture)

    %{program: program, props: props()}
  end

  defp compile_timeout_program! do
    {:ok, program} = QuickBEAM.VM.compile("while (true) {}", filename: "scheduler-timeout.js")
    program
  end

  defp render!(fixture, engine) do
    handler = fn [] -> fixture.props end

    {:ok, measurement} =
      QuickBEAM.VM.measure(
        fixture.program,
        [engine: engine, handlers: %{"load_props" => handler}] ++ @eval_opts
      )

    unless match?({:ok, _rendered}, measurement.result),
      do: raise("Vue scheduler probe failed: #{inspect(measurement.result)}")

    measurement
  end

  defp observe_ticker(operation) do
    owner = self()
    ref = make_ref()
    ticker = spawn_link(fn -> ticker(owner, ref) end)
    started = now_us()
    result = operation.()
    ended = now_us()
    send(ticker, {:stop, ref})
    timestamps = collect_ticks(ref, [])
    points = [started | timestamps] ++ [ended]

    gaps =
      points |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [left, right] -> right - left end)

    %{
      wall_time_us: ended - started,
      ticker_gaps: gaps,
      ticker_count: length(timestamps),
      result: result
    }
  end

  defp ticker(owner, ref) do
    receive do
      {:stop, ^ref} -> send(owner, {:ticker_stopped, ref})
    after
      1 ->
        send(owner, {:ticker_tick, ref, now_us()})
        ticker(owner, ref)
    end
  end

  defp collect_ticks(ref, timestamps) do
    receive do
      {:ticker_tick, ^ref, timestamp} -> collect_ticks(ref, [timestamp | timestamps])
      {:ticker_stopped, ^ref} -> Enum.reverse(timestamps)
    after
      1_000 -> raise "ticker did not stop"
    end
  end

  defp summarize_observations(observations) do
    gaps = Enum.flat_map(observations, & &1.ticker_gaps)

    %{
      wall: observations |> Enum.map(& &1.wall_time_us) |> summarize(),
      gap: summarize(gaps),
      ticks: observations |> Enum.map(& &1.ticker_count) |> summarize()
    }
  end

  defp summarize(values) do
    values = Enum.sort(values)
    %{median: percentile(values, 0.50), p95: percentile(values, 0.95), max: List.last(values)}
  end

  defp percentile(values, fraction) do
    index = (fraction * (length(values) - 1)) |> Float.ceil() |> trunc()
    Enum.at(values, index)
  end

  defp enforce_gates!(render, timeout) do
    if render.gap.max > @max_ticker_gap_us,
      do: raise("ticker gap #{render.gap.max} µs exceeded #{@max_ticker_gap_us} µs")

    if timeout.p95 > @max_timeout_wall_us,
      do: raise("timeout p95 #{timeout.p95} µs exceeded #{@max_timeout_wall_us} µs")
  end

  defp report(engine, samples, baseline_ms, render, baseline, timeout) do
    """
    # BEAM VM single-scheduler probe

    Run with `ERL_FLAGS="+S 1:1"`. The pinned Vue SSR fixture and a periodic BEAM
    ticker share one scheduler. The baseline sleeps for the median render wall
    time, allowing the same ticker to run without #{engine} work.

    - Engine: #{engine}
    - Git base: `#{command("git", ["rev-parse", "--short", "HEAD"])}`
    - Working tree at measurement: #{tree_state()}
    - Generated: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
    - Elixir: #{System.version()}
    - OTP: #{System.otp_release()}
    - ERTS: #{:erlang.system_info(:version)}
    - OS: #{command("uname", ["-sr"])}
    - Architecture: #{:erlang.system_info(:system_architecture)}
    - CPU: #{cpu_model()}
    - Online schedulers: #{System.schedulers_online()}
    - Vue probe memory limit: 512 MB
    - Samples: #{samples}

    | workload | wall median | wall p95 | ticker gap median | ticker gap p95 | ticker gap max | ticks median |
    |---|---:|---:|---:|---:|---:|---:|
    | Vue SSR | #{duration(render.wall.median)} | #{duration(render.wall.p95)} | #{duration(render.gap.median)} | #{duration(render.gap.p95)} | #{duration(render.gap.max)} | #{render.ticks.median} |
    | sleep baseline (#{baseline_ms} ms target) | #{duration(baseline.wall.median)} | #{duration(baseline.wall.p95)} | #{duration(baseline.gap.median)} | #{duration(baseline.gap.p95)} | #{duration(baseline.gap.max)} | #{baseline.ticks.median} |

    Acceptance bound: Vue SSR ticker gap ≤ #{duration(@max_ticker_gap_us)}.

    ## Timeout containment

    An infinite JavaScript loop was evaluated with a 50 ms outer timeout.

    | timeout | wall median | wall p95 | wall max | median overshoot |
    |---:|---:|---:|---:|---:|
    | 50 ms | #{duration(timeout.median)} | #{duration(timeout.p95)} | #{duration(timeout.max)} | #{duration(max(timeout.median - 50_000, 0))} |

    Acceptance bound: timeout p95 ≤ #{duration(@max_timeout_wall_us)}.
    """
  end

  defp now_us, do: System.monotonic_time(:microsecond)

  defp duration(microseconds) when microseconds >= 1_000,
    do: "#{Float.round(microseconds / 1_000, 2)} ms"

  defp duration(microseconds), do: "#{microseconds} µs"

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

  defp engine!("interpreter"), do: :interpreter
  defp engine!("compiler"), do: :compiler

  defp engine!(engine),
    do: raise(ArgumentError, "engine must be interpreter or compiler, got: #{inspect(engine)}")

  defp maybe_start_compiler!(:interpreter), do: :ok

  defp maybe_start_compiler!(:compiler) do
    case Compiler.start_link(capacity: 8) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "compiler start failed: #{inspect(reason)}"
    end
  end

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive!(value, name),
    do: raise(ArgumentError, "#{name} must be positive, got: #{inspect(value)}")

  defp props do
    %{
      "title" => "Scheduler fairness",
      "products" => [
        %{
          "id" => 1,
          "name" => "Product 1",
          "inStock" => true,
          "priceCents" => 1_299
        }
      ]
    }
  end
end

QuickBEAM.Bench.VMSchedulerProbe.run(System.argv())
