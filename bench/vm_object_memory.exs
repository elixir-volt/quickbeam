defmodule QuickBEAM.Bench.VMObjectMemory do
  @moduledoc """
  Measures the isolated VM's array-heavy allocation path.
  """

  @default_count 20_000
  @default_samples 30

  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [count: :integer, samples: :integer, output: :string])

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    count = positive!(Keyword.get(opts, :count, @default_count), :count)
    samples = positive!(Keyword.get(opts, :samples, @default_samples), :samples)
    program = compile_workload!(count)

    Enum.each(1..3, fn _iteration -> measure!(program, count) end)
    measurements = Enum.map(1..samples, fn _iteration -> measure!(program, count) end)
    report = report(count, samples, measurements)
    IO.write(report)

    if output = opts[:output] do
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, report)
    end
  end

  defp compile_workload!(count) do
    source = """
    let values = [];
    for (let index = 0; index < #{count}; index++) values.push(index);
    globalThis.__quickbeamRetainedArray = values;
    values.length;
    """

    {:ok, program} = QuickBEAM.VM.compile(source, filename: "vm_object_memory.js")
    program
  end

  defp measure!(program, count) do
    {:ok, measurement} =
      QuickBEAM.VM.measure(program,
        max_steps: count * 20 + 10_000,
        memory_limit: 256_000_000,
        timeout: 5_000
      )

    if measurement.result != {:ok, count},
      do: raise("array allocation measurement failed: #{inspect(measurement.result)}")

    measurement
  end

  defp report(count, samples, measurements) do
    metadata = metadata()
    wall = Enum.map(measurements, & &1.wall_time_us)
    reductions = Enum.map(measurements, & &1.reductions)
    memory = Enum.map(measurements, & &1.process_memory_bytes)
    first = hd(measurements)

    """
    # BEAM VM object-memory measurements

    This fixture retains one JavaScript array populated by sequential
    `Array.prototype.push` calls. It measures the canonical interpreter path,
    including isolated-process startup and result conversion. Endpoint process
    memory is not a sampled peak or operating-system RSS value.

    ## Environment

    - Git base: `#{metadata.git}`
    - Working tree at measurement: #{metadata.tree_state}
    - Generated: #{metadata.generated}
    - Elixir: #{metadata.elixir}
    - OTP: #{metadata.otp}
    - ERTS: #{metadata.erts}
    - Architecture: #{metadata.architecture}
    - CPU: #{metadata.cpu}
    - Array entries: #{count}
    - Samples after 3 warmups: #{samples}

    | wall median | wall p95 | reductions median | endpoint process memory | VM steps | logical memory |
    |---:|---:|---:|---:|---:|---:|
    | #{format_us(median(wall))} | #{format_us(percentile(wall, 0.95))} | #{median(reductions)} | #{format_bytes(median(memory))} | #{first.steps} | #{format_bytes(first.logical_memory_bytes)} |

    VM steps and logical memory are deterministic. The benchmark intentionally
    retains the array until measurement so the endpoint observation includes
    its live representation.
    """
  end

  defp median(values), do: percentile(values, 0.5)

  defp percentile(values, fraction) do
    values = Enum.sort(values)
    index = (fraction * (length(values) - 1)) |> Float.ceil() |> trunc()
    Enum.at(values, index)
  end

  defp format_us(value) when value >= 1_000,
    do: "#{Float.round(value / 1_000, 2)} ms"

  defp format_us(value), do: "#{value} µs"

  defp format_bytes(value) when value >= 1024 * 1024,
    do: "#{Float.round(value / (1024 * 1024), 2)} MiB"

  defp format_bytes(value) when value >= 1024,
    do: "#{Float.round(value / 1024, 1)} KiB"

  defp format_bytes(value), do: "#{value} B"

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive!(value, name),
    do: raise(ArgumentError, "#{name} must be positive, got: #{inspect(value)}")

  defp metadata do
    %{
      git: command("git", ["rev-parse", "--short", "HEAD"]),
      tree_state:
        if(command("git", ["status", "--porcelain"]) == "", do: "clean", else: "modified"),
      generated: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      elixir: System.version(),
      otp: System.otp_release(),
      erts: to_string(:erlang.system_info(:version)),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      cpu: cpu_model()
    }
  end

  defp command(executable, arguments) do
    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _error -> "unknown"
    end
  end

  defp cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, cpuinfo} ->
        cpuinfo
        |> String.split("\n")
        |> Enum.find_value("unknown", &cpu_model_from_line/1)

      {:error, _reason} ->
        command("sysctl", ["-n", "machdep.cpu.brand_string"])
    end
  end

  defp cpu_model_from_line(line) do
    case String.split(line, ":", parts: 2) do
      ["model name", model] -> String.trim(model)
      [key, model] -> if(String.trim(key) == "model name", do: String.trim(model))
      _line -> nil
    end
  end
end

QuickBEAM.Bench.VMObjectMemory.run(System.argv())
