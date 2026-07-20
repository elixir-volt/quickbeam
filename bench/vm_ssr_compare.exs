defmodule QuickBEAM.Bench.VMSSRCompare do
  @moduledoc """
  Compares native QuickJS and the pinned BEAM VM on identical SSR fixtures.

  Native warm mode loads the framework bundle once and calls its render function
  repeatedly. Native isolated mode starts a bare runtime, loads precompiled
  request bytecode, renders, and stops the runtime for every sample. The public
  interpreter initializes pinned setup bytecode and calls the same named render
  function in a fresh owner-local heap. Internal compiler modes execute the
  equivalent precompiled request wrapper. Source compilation and compiler-service
  startup are excluded; all returned values must match exactly.
  """

  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Compiler.Pool
  alias QuickBEAM.VM.Runtime.Engine

  @default_samples 50
  @default_warmup 10

  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [samples: :integer, warmup: :integer])

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    samples = positive!(Keyword.get(opts, :samples, @default_samples), :samples)
    warmup = non_negative!(Keyword.get(opts, :warmup, @default_warmup), :warmup)
    ensure_compiler!()

    IO.puts(
      "OTP=#{System.otp_release()} schedulers=#{System.schedulers_online()} " <>
        "samples=#{samples} warmup=#{warmup}"
    )

    IO.puts("Source compilation, bundle setup, and compiler-service startup are excluded.")

    IO.puts(
      "native_warm reuses an initialized runtime; native_isolated includes bare " <>
        "runtime start/load/render/stop."
    )

    Enum.each(fixtures(), &compare_fixture(&1, samples, warmup))
  end

  defp compare_fixture(spec, sample_count, warmup) do
    setup_source = setup_source!(spec)

    request_source =
      setup_source <>
        "\nglobalThis.__quickbeamSSRResult = globalThis.__quickbeamRender();\n" <>
        "globalThis.__quickbeamGetSSRResult = async function(){ " <>
        "return await globalThis.__quickbeamSSRResult; };\n" <>
        "globalThis.__quickbeamSSRResult;\n"

    handlers = %{"load_props" => fn [] -> props() end}

    {:ok, compile_runtime} = QuickBEAM.start(apis: false)
    {:ok, setup_bytecode} = QuickBEAM.compile(compile_runtime, setup_source)
    {:ok, request_bytecode} = QuickBEAM.compile(compile_runtime, request_source)
    :ok = QuickBEAM.stop(compile_runtime)

    {:ok, call_program} = QuickBEAM.VM.decode(setup_bytecode)
    {:ok, request_program} = QuickBEAM.VM.decode(request_bytecode)
    {:ok, pinned_call} = QuickBEAM.VM.pin(call_program)
    {:ok, pinned_request} = QuickBEAM.VM.pin(request_program)

    vm_opts = [
      handlers: handlers,
      profile: :ssr,
      max_steps: spec.max_steps,
      memory_limit: spec.memory_limit,
      timeout: 10_000
    ]

    {:ok, warm_runtime} = QuickBEAM.start(handlers: handlers, apis: false)
    {:ok, _namespace} = QuickBEAM.load_bytecode(warm_runtime, setup_bytecode)

    runners = [
      native_warm: fn ->
        QuickBEAM.call(warm_runtime, "__quickbeamRender", [], timeout: 10_000)
      end,
      native_isolated: fn -> native_isolated(request_bytecode, handlers) end,
      interpreter: fn ->
        QuickBEAM.VM.call(pinned_call, "__quickbeamRender", [], vm_opts)
      end,
      compiler_pure: fn -> compiler_eval(pinned_request, :pure_v1, vm_opts) end,
      compiler_scalar: fn -> compiler_eval(pinned_request, :scalar_v1, vm_opts) end
    ]

    try do
      expected = successful!(runners[:native_warm].())
      warm!(runners, expected, warmup)
      samples = sample!(runners, expected, sample_count)
      report(spec.name, samples)
    after
      QuickBEAM.stop(warm_runtime)
      QuickBEAM.VM.unpin(pinned_call)
      QuickBEAM.VM.unpin(pinned_request)
    end
  end

  defp compiler_eval(program, profile, opts),
    do: Engine.eval(program, [engine: :compiler, compiler_profile: profile] ++ opts)

  defp native_isolated(bytecode, handlers) do
    case QuickBEAM.start(handlers: handlers, apis: false) do
      {:ok, runtime} ->
        try do
          case QuickBEAM.load_bytecode(runtime, bytecode) do
            {:ok, _namespace} ->
              QuickBEAM.call(runtime, "__quickbeamGetSSRResult", [], timeout: 10_000)

            {:error, _reason} = error ->
              error
          end
        after
          QuickBEAM.stop(runtime)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp warm!(_runners, _expected, 0), do: :ok

  defp warm!(runners, expected, count) do
    Enum.each(runners, fn {_name, runner} ->
      Enum.each(1..count, fn _iteration -> assert_same!(runner.(), expected) end)
    end)
  end

  defp sample!(runners, expected, count) do
    initial = Map.new(runners, fn {name, _runner} -> {name, []} end)
    runner_count = length(runners)

    samples =
      Enum.reduce(0..(count - 1), initial, fn iteration, samples ->
        runners
        |> rotate(rem(iteration, runner_count))
        |> Enum.reduce(samples, fn {name, runner}, samples ->
          {elapsed_us, result} = :timer.tc(runner)
          assert_same!(result, expected)
          Map.update!(samples, name, &[elapsed_us | &1])
        end)
      end)

    Map.new(samples, fn {name, values} -> {name, summarize(values)} end)
  end

  defp rotate(values, 0), do: values

  defp rotate(values, count) do
    {left, right} = Enum.split(values, count)
    right ++ left
  end

  defp report(name, samples) do
    native_warm = samples.native_warm.median
    native_isolated = samples.native_isolated.median

    IO.puts("\n#{name}")

    IO.puts("  mode              median      p95    vs warm  vs isolated")

    Enum.each(
      [:native_warm, :native_isolated, :interpreter, :compiler_pure, :compiler_scalar],
      fn mode ->
        result = Map.fetch!(samples, mode)

        IO.puts(
          "  #{mode |> Atom.to_string() |> String.pad_trailing(17)} " <>
            "#{format_ms(result.median) |> String.pad_leading(7)}ms " <>
            "#{format_ms(result.p95) |> String.pad_leading(7)}ms " <>
            "#{format_ratio(result.median, native_warm) |> String.pad_leading(9)} " <>
            "#{format_ratio(result.median, native_isolated) |> String.pad_leading(12)}"
        )
      end
    )
  end

  defp summarize(samples) do
    sorted = Enum.sort(samples)

    %{
      min: hd(sorted),
      median: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95)
    }
  end

  defp percentile(sorted, fraction) do
    index = max(ceil(length(sorted) * fraction) - 1, 0)
    Enum.at(sorted, index)
  end

  defp successful!({:ok, value}), do: value
  defp successful!(other), do: raise("unexpected result: #{inspect(other)}")

  defp assert_same!({:ok, value}, value), do: :ok

  defp assert_same!(actual, expected),
    do: raise("result mismatch: #{inspect(actual)} != #{inspect(expected)}")

  defp format_ms(microseconds),
    do: :erlang.float_to_binary(microseconds / 1_000, decimals: 3)

  defp format_ratio(value, baseline),
    do: :erlang.float_to_binary(value / baseline, decimals: 2) <> "x"

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive!(value, name),
    do: raise(ArgumentError, "#{name} must be positive, got: #{inspect(value)}")

  defp non_negative!(value, _name) when is_integer(value) and value >= 0, do: value

  defp non_negative!(value, name),
    do: raise(ArgumentError, "#{name} must be non-negative, got: #{inspect(value)}")

  defp setup_source!(spec) do
    source = File.read!(spec.fixture)

    setup_entry =
      source
      |> String.replace(
        "globalThis.__quickbeamSSRResult = (async function",
        "globalThis.__quickbeamRender = async function"
      )
      |> String.replace("})();\n\nglobalThis.__quickbeamSSRResult;", "};")

    if setup_entry == source,
      do: raise("failed to rewrite SSR entry #{spec.fixture}")

    temporary = Path.join(Path.dirname(spec.fixture), ".native-vm-#{Path.basename(spec.fixture)}")
    File.write!(temporary, setup_entry)

    try do
      {:ok, bundled} = QuickBEAM.JS.bundle_file(temporary, spec.bundle_opts)
      bundled
    after
      File.rm!(temporary)
    end
  end

  defp props do
    %{
      "title" => "Native versus BEAM",
      "products" =>
        Enum.map(1..8, fn id ->
          %{
            "id" => id,
            "name" => "Product #{id}",
            "inStock" => rem(id, 2) == 1,
            "priceCents" => 1_199 + id * 100
          }
        end)
    }
  end

  defp fixtures do
    [
      %{
        name: "Preact 10.29.7",
        fixture: "test/fixtures/vm/preact_ssr.js",
        bundle_opts: [format: :esm, minify: false],
        max_steps: 20_000_000,
        memory_limit: 64_000_000
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
        max_steps: 50_000_000,
        memory_limit: 256_000_000
      },
      %{
        name: "Svelte 5.56.4",
        fixture: "test/fixtures/vm/svelte_ssr.js",
        bundle_opts: [format: :esm, minify: true],
        max_steps: 20_000_000,
        memory_limit: 64_000_000
      }
    ]
  end

  defp ensure_compiler! do
    case Process.whereis(Pool) do
      nil ->
        {:ok, _pid} = Compiler.start_link(capacity: 32)
        :ok

      _pid ->
        :ok
    end
  end
end

QuickBEAM.Bench.VMSSRCompare.run(System.argv())
