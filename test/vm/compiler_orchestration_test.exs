defmodule QuickBEAM.VM.CompilerOrchestrationTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.{Compiler, Measurement}
  alias QuickBEAM.VM.Compiler.ModulePool

  test "requires an explicitly supervised compiler service" do
    assert {:ok, program} = QuickBEAM.VM.compile("40 + 2")

    assert {:error, {:compiler_error, {:compiler_pool_unavailable, ModulePool}}} =
             QuickBEAM.VM.eval(program, engine: :compiler)
  end

  test "matches interpreter and native QuickJS for decoded pure fixtures" do
    start_compiler()
    assert {:ok, runtime} = QuickBEAM.start(apis: false)

    try do
      for source <- ["40 + 2", "6 * 7", "10 > 3", "true ? 11 : 22", "(5 << 2) | 1"] do
        assert {:ok, program} = QuickBEAM.VM.compile(source)
        assert {:ok, expected} = QuickBEAM.eval(runtime, source)
        assert QuickBEAM.VM.eval(program) == {:ok, expected}
        assert QuickBEAM.VM.eval(program, engine: :compiler) == {:ok, expected}
      end
    after
      QuickBEAM.stop(runtime)
    end
  end

  test "preserves JavaScript error identity across native, interpreter, and compiler tiers" do
    start_compiler()
    source = "(function explode(){ throw new TypeError('boom') })()"
    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: "compiler-error.js")
    assert {:ok, runtime} = QuickBEAM.start(apis: false)

    try do
      assert {:error, native_error} = QuickBEAM.eval(runtime, source)
      assert {:error, interpreted_error} = QuickBEAM.VM.eval(program)
      assert {:error, compiled_error} = QuickBEAM.VM.eval(program, engine: :compiler)

      assert %QuickBEAM.JSError{name: "TypeError", message: "boom"} = native_error
      assert %QuickBEAM.JSError{name: "TypeError", message: "boom"} = interpreted_error
      assert compiled_error == interpreted_error
    after
      QuickBEAM.stop(runtime)
    end
  end

  test "re-enters cached compilation for nested bytecode function frames" do
    start_compiler()
    expression = Enum.join(List.duplicate("value", 40), " + ")
    source = "(function add(value) { return #{expression} })(1)"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 40} = QuickBEAM.VM.eval(program, engine: :compiler)

    stats = ModulePool.stats(ModulePool)
    assert stats.counts.ready >= 1
    assert stats.leases == 0
  end

  test "caches bounded owner-local skip decisions" do
    start_compiler()
    assert {:ok, program} = QuickBEAM.VM.compile("(function add(value) { return value + 1 })(41)")
    assert {:ok, 42, execution} = Compiler.start(program)

    decisions = execution.compiler_context.decisions
    assert map_size(decisions) == 2
    assert Enum.count(decisions, fn {_id, decision} -> decision == :skip end) == 2
  end

  test "uses the loaded artifact before repeating warm lowering" do
    start_compiler()
    assert {:ok, program} = QuickBEAM.VM.compile("40 + 2")
    assert {:ok, 42, cold_execution} = Compiler.start(program)
    assert {:ok, 42, warm_execution} = Compiler.start(program)

    assert Enum.any?(cold_execution.compiler_context.decisions, fn {_id, decision} ->
             match?({:compile, _, _}, decision)
           end)

    assert Enum.any?(warm_execution.compiler_context.decisions, fn {_id, decision} ->
             match?({:cached, _}, decision)
           end)
  end

  test "caps owner-local eligibility metadata across many nested functions" do
    start_compiler()

    source =
      0..299
      |> Enum.map_join(",", fn value -> "(function(){return #{value}})()" end)

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 299, execution} = Compiler.start(program)
    assert map_size(execution.compiler_context.decisions) == 256
  end

  test "preserves stack limits and tail calls across nested compiler re-entry" do
    start_compiler()

    assert {:ok, recursive} =
             QuickBEAM.VM.compile("(function recurse(n){return 1+recurse(n+1)})(0)")

    expected = {:error, {:limit_exceeded, :stack_depth, 6}}
    assert QuickBEAM.VM.eval(recursive, max_stack_depth: 5) == expected
    assert QuickBEAM.VM.eval(recursive, engine: :compiler, max_stack_depth: 5) == expected

    assert {:ok, tail_recursive} =
             QuickBEAM.VM.compile(
               "(function recurse(n){if(n===0)return 0;return recurse(n-1)})(1000)"
             )

    assert {:ok, 0} =
             QuickBEAM.VM.eval(tail_recursive, engine: :compiler, max_stack_depth: 2)
  end

  test "deoptimizes into asynchronous handlers without duplicating effects" do
    start_compiler()
    assert {:ok, program} = QuickBEAM.VM.compile("Beam.call('double', 21)")
    parent = self()

    handler = fn [value] ->
      send(parent, :handler_called)
      value * 2
    end

    assert {:ok, 42} =
             QuickBEAM.VM.eval(program,
               engine: :compiler,
               handlers: %{"double" => handler}
             )

    assert_receive :handler_called
    refute_receive :handler_called, 20
  end

  test "cancels outstanding handlers when a compiled evaluation times out" do
    start_compiler()
    assert {:ok, program} = QuickBEAM.VM.compile("Beam.call('wait')")

    assert {:ok, 1} =
             QuickBEAM.VM.eval(program,
               engine: :compiler,
               handlers: %{"wait" => fn [] -> 1 end},
               timeout: 1_000
             )

    parent = self()

    handler = fn [] ->
      send(parent, {:compiler_handler_started, self()})
      Process.sleep(:infinity)
    end

    assert {:error, {:limit_exceeded, :timeout, 200}} =
             QuickBEAM.VM.eval(program,
               engine: :compiler,
               handlers: %{"wait" => handler},
               timeout: 200
             )

    assert_receive {:compiler_handler_started, handler_pid}
    monitor = Process.monitor(handler_pid)
    assert_receive {:DOWN, ^monitor, :process, ^handler_pid, _reason}, 1_000
  end

  test "preserves deterministic measurement counters" do
    start_compiler()
    assert {:ok, program} = QuickBEAM.VM.compile("({answer: 40 + 2})")

    assert {:ok, %Measurement{} = interpreted} = QuickBEAM.VM.measure(program)

    assert {:ok, %Measurement{} = compiled} =
             QuickBEAM.VM.measure(program, engine: :compiler)

    assert compiled.result == interpreted.result
    assert compiled.steps == interpreted.steps
    assert compiled.logical_memory_bytes == interpreted.logical_memory_bytes
    assert interpreted.compiler_counters == nil
    assert compiled.compiler_counters.profile == :pure_v1
    assert compiled.compiler_counters.frame_attempts > 0
    assert compiled.compiler_counters.generated_steps <= compiled.steps
    assert compiled.process_memory_bytes > 0
    assert compiled.reductions > 0
  end

  test "preserves step limits and outer timeout containment" do
    start_compiler()
    assert {:ok, finite} = QuickBEAM.VM.compile("40 + 2")

    expected = {:error, {:limit_exceeded, :steps, 2}}
    assert QuickBEAM.VM.eval(finite, max_steps: 2) == expected
    assert QuickBEAM.VM.eval(finite, engine: :compiler, max_steps: 2) == expected

    memory_error = {:error, {:limit_exceeded, :memory_bytes, 1}}
    assert QuickBEAM.VM.eval(finite, memory_limit: 1) == memory_error
    assert QuickBEAM.VM.eval(finite, engine: :compiler, memory_limit: 1) == memory_error

    assert {:ok, loop} = QuickBEAM.VM.compile("while (true) {}")

    assert {:error, {:limit_exceeded, :timeout, 50}} =
             QuickBEAM.VM.eval(loop,
               engine: :compiler,
               max_steps: 100_000_000,
               timeout: 50
             )
  end

  test "matches the pinned Preact SSR fixture through async deoptimization" do
    start_compiler()

    assert {:ok, source} =
             QuickBEAM.JS.bundle_file("test/fixtures/vm/preact_ssr.js",
               format: :esm,
               minify: false
             )

    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: "preact_ssr.js")

    props = %{
      "title" => "Compiler",
      "products" => [
        %{"id" => 1, "name" => "Product 1", "inStock" => true, "priceCents" => 1_299}
      ]
    }

    options = [
      handlers: %{"load_props" => fn [] -> props end},
      max_steps: 20_000_000,
      timeout: 2_000
    ]

    expected = QuickBEAM.VM.eval(program, options)
    assert QuickBEAM.VM.eval(program, [engine: :compiler] ++ options) == expected

    assert QuickBEAM.VM.eval(
             program,
             [engine: :compiler, compiler_profile: :scalar_v1] ++ options
           ) == expected
  end

  test "admits and reuses one bounded entry region for an oversized scalar function" do
    start_compiler()
    body = Enum.map_join(1..100, "", fn _index -> "value=value+1;" end)

    assert {:ok, program} =
             QuickBEAM.VM.compile("(function(){let value=0;#{body}return value})()")

    assert {:ok, 100} =
             QuickBEAM.VM.eval(program,
               engine: :compiler,
               compiler_profile: :scalar_v1,
               max_steps: 10_000
             )

    opts = [
      engine: :compiler,
      compiler_profile: :scalar_v1,
      compiler_regions: true,
      max_steps: 10_000
    ]

    assert {:ok, 100} = QuickBEAM.VM.eval(program, opts)
    assert {:ok, 100} = QuickBEAM.VM.eval(program, opts)

    assert {:ok, interpreted} = QuickBEAM.VM.measure(program, max_steps: 10_000)
    assert {:ok, admitted} = QuickBEAM.VM.measure(program, opts)
    assert admitted.result == interpreted.result
    assert admitted.steps == interpreted.steps
    assert admitted.logical_memory_bytes == interpreted.logical_memory_bytes
    assert admitted.compiler_counters.generated_steps == 32
    assert admitted.compiler_counters.region_compiled == 1

    assert {:ok, cached} = QuickBEAM.VM.measure(program, opts)
    assert cached.result == interpreted.result
    assert cached.steps == interpreted.steps
    assert cached.logical_memory_bytes == interpreted.logical_memory_bytes
    assert cached.compiler_counters.generated_steps == 32
    assert cached.compiler_counters.region_hot > 0
    assert cached.compiler_counters.region_compiled == 0
    assert ModulePool.stats(ModulePool).region_admissions == 2

    Enum.each([1, 16, 32, 33, interpreted.steps - 1], fn step_limit ->
      interpreter_result = QuickBEAM.VM.eval(program, max_steps: step_limit)
      compiler_result = QuickBEAM.VM.eval(program, Keyword.put(opts, :max_steps, step_limit))
      assert compiler_result == interpreter_result
    end)
  end

  test "shares cached generated code across isolated evaluation owners" do
    start_compiler()
    assert {:ok, program} = QuickBEAM.VM.compile("(20 + 1) * 2")

    tasks =
      for _ <- 1..40 do
        Task.async(fn -> QuickBEAM.VM.eval(program, engine: :compiler) end)
      end

    assert Task.await_many(tasks, 5_000) == List.duplicate({:ok, 42}, 40)

    stats = ModulePool.stats(ModulePool)
    assert stats.counts.ready >= 1
    assert stats.leases == 0
    assert stats.compilations == 0
  end

  test "validates compiler-facing evaluation options" do
    assert {:ok, program} = QuickBEAM.VM.compile("42")

    assert {:error, {:invalid_option, :engine, :native}} =
             QuickBEAM.VM.eval(program, engine: :native)

    assert {:error, {:invalid_option, :compiler_pool, "pool"}} =
             QuickBEAM.VM.eval(program, engine: :compiler, compiler_pool: "pool")

    assert {:error, {:invalid_option, :compiler_profile, :unbounded}} =
             QuickBEAM.VM.eval(program, engine: :compiler, compiler_profile: :unbounded)

    assert {:error, {:invalid_option, :compiler_region_probe, :always}} =
             QuickBEAM.VM.eval(program, engine: :compiler, compiler_region_probe: :always)

    assert {:error, {:invalid_option, :compiler_regions, :always}} =
             QuickBEAM.VM.eval(program, engine: :compiler, compiler_regions: :always)
  end

  defp start_compiler do
    start_supervised!({Compiler, capacity: 4})
  end
end
