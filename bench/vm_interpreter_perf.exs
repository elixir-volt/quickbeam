defmodule QuickBEAM.Bench.VMInterpreterPerf do
  @moduledoc "Workload driver for non-instrumented BeamAsm/perf sampling."

  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [mode: :string, iterations: :integer, warmup: :integer]
      )

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(positional ++ invalid)}")

    mode = mode!(Keyword.get(opts, :mode, "shared"))
    iterations = positive!(Keyword.get(opts, :iterations, 500), :iterations)
    warmup = non_negative!(Keyword.get(opts, :warmup, 10), :warmup)
    {:ok, source} = bundle()
    {:ok, decoded_program} = QuickBEAM.VM.compile(source, filename: fixture())

    program =
      if mode == :shared do
        {:ok, shared_program} = QuickBEAM.VM.share_program(decoded_program)
        shared_program
      else
        decoded_program
      end

    options = [
      profile: :ssr,
      handlers: %{"load_props" => fn [] -> props() end},
      max_steps: 50_000_000,
      memory_limit: 256_000_000,
      timeout: 5_000
    ]

    run = operation(mode, program, options)
    Enum.each(1..warmup//1, fn _iteration -> successful!(run.()) end)

    started = System.monotonic_time()
    Enum.each(1..iterations, fn _iteration -> successful!(run.()) end)
    elapsed = System.monotonic_time() - started
    elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)

    IO.puts("mode=#{mode} iterations=#{iterations} elapsed_ms=#{elapsed_ms}")

    if mode == :shared, do: QuickBEAM.VM.release_program(program)
  end

  defp operation(:caller, program, options),
    do: fn -> QuickBEAM.VM.eval(program, [isolation: :caller] ++ options) end

  defp operation(_isolated, program, options),
    do: fn -> QuickBEAM.VM.eval(program, options) end

  defp successful!({:ok, _result}), do: :ok
  defp successful!(result), do: raise("unexpected evaluation result: #{inspect(result)}")

  defp fixture, do: "test/fixtures/vm/vue_ssr.js"

  defp bundle do
    QuickBEAM.JS.bundle_file(fixture(),
      format: :esm,
      minify: true,
      define: %{
        "__VUE_OPTIONS_API__" => "true",
        "__VUE_PROD_DEVTOOLS__" => "false",
        "__VUE_PROD_HYDRATION_MISMATCH_DETAILS__" => "false",
        "process.env.NODE_ENV" => ~s("production")
      }
    )
  end

  defp props do
    %{
      "title" => "Profile",
      "products" => [
        %{"id" => 1, "name" => "Product 1", "inStock" => true, "priceCents" => 1299}
      ]
    }
  end

  defp mode!("caller"), do: :caller
  defp mode!("copied"), do: :copied
  defp mode!("shared"), do: :shared
  defp mode!(mode), do: raise(ArgumentError, "invalid mode: #{inspect(mode)}")

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value
  defp positive!(value, name), do: raise(ArgumentError, "invalid #{name}: #{inspect(value)}")
  defp non_negative!(value, _name) when is_integer(value) and value >= 0, do: value

  defp non_negative!(value, name),
    do: raise(ArgumentError, "invalid #{name}: #{inspect(value)}")
end

QuickBEAM.Bench.VMInterpreterPerf.run(System.argv())
