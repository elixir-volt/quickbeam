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

    assert QuickBEAM.VM.eval(program, [engine: :compiler] ++ options) ==
             QuickBEAM.VM.eval(program, options)
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
  end

  defp start_compiler do
    start_supervised!({Compiler, capacity: 4})
  end
end
