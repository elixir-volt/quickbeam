defmodule QuickBEAM.VM.CallTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM

  test "calls a named global with native-compatible arguments and fresh state" do
    source = """
    globalThis.counter = 0;
    function render(input) {
      counter += 1;
      return {
        count: counter,
        label: input.label,
        thisIsGlobal: this === globalThis
      };
    }
    """

    assert {:ok, program} = VM.compile(source)
    argument = %{"label" => "catalog"}
    expected = %{"count" => 1, "label" => "catalog", "thisIsGlobal" => true}

    assert {:ok, ^expected} = VM.call(program, "render", [argument])
    assert {:ok, ^expected} = VM.call(program, "render", [argument])

    assert {:ok, runtime} = QuickBEAM.start(apis: false)

    try do
      assert {:ok, _value} = QuickBEAM.eval(runtime, source)
      assert {:ok, ^expected} = QuickBEAM.call(runtime, "render", [argument])
    after
      QuickBEAM.stop(runtime)
    end
  end

  test "awaits Promise results and asynchronous BEAM handlers" do
    source = """
    async function render(value) {
      const doubled = await Beam.call("double", value);
      return await Promise.resolve(doubled + 1);
    }
    """

    assert {:ok, program} = VM.compile(source)

    assert {:ok, 43} =
             VM.call(program, "render", [21],
               handlers: %{"double" => fn [value] -> value * 2 end}
             )
  end

  test "finishes asynchronous program initialization before calling the target" do
    source = """
    globalThis.ready = false;
    function render() { return globalThis.ready; }
    Promise.resolve().then(() => { globalThis.ready = true; })
    """

    assert {:ok, program} = VM.compile(source)
    assert {:ok, true} = VM.call(program, "render")
  end

  test "reports missing and non-callable globals as stable JavaScript errors" do
    assert {:ok, program} = VM.compile("globalThis.value = 42")

    assert {:error, %QuickBEAM.JSError{name: "ReferenceError", message: message}} =
             VM.call(program, "missing")

    assert message == "missing is not defined"

    assert {:error, %QuickBEAM.JSError{name: "TypeError", message: message}} =
             VM.call(program, "value")

    assert message =~ "is not a function"
  end

  test "supports pinned calls and public call measurements" do
    assert {:ok, program} = VM.compile("function add(left, right) { return left + right }")
    assert {:ok, pinned} = VM.pin(program)

    try do
      assert {:ok, 42} = VM.call(pinned, "add", [20, 22])
      assert {:ok, 42} = VM.call(pinned, "add", [20, 22], isolation: :caller)
      assert {:ok, measurement} = VM.measure_call(pinned, "add", [20, 22])
      assert measurement.result == {:ok, 42}
      assert measurement.steps > 0
      assert measurement.logical_memory_bytes > 0
      assert measurement.process_memory_bytes > 0
      refute Map.has_key?(measurement, :compiler_counters)
    after
      assert :ok = VM.unpin(pinned)
    end
  end

  test "charges initialization and calls under one deterministic step limit" do
    assert {:ok, program} =
             VM.compile(
               "function sum(n) { let total = 0; while (n > 0) { total += n--; } return total }"
             )

    assert {:ok, measurement} = VM.measure_call(program, "sum", [20])
    assert measurement.result == {:ok, 210}
    assert measurement.steps > 1

    assert {:error, {:limit_exceeded, :steps, limit}} =
             VM.call(program, "sum", [20], max_steps: measurement.steps - 1)

    assert limit == measurement.steps - 1
  end

  test "isolates concurrent pinned calls and their mutable globals" do
    assert {:ok, program} =
             VM.compile(
               "let count = 0; async function render() { await Promise.resolve(); return ++count }"
             )

    assert {:ok, pinned} = VM.pin(program)

    try do
      results =
        1..20
        |> Task.async_stream(fn _index -> VM.call(pinned, "render") end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert results == List.duplicate({:ok, 1}, 20)
    after
      assert :ok = VM.unpin(pinned)
    end
  end

  test "cancels an asynchronous handler when a call times out" do
    parent = self()

    handler = fn [] ->
      send(parent, {:handler_started, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, program} =
             VM.compile("async function render() { return await Beam.call('wait') }")

    assert {:error, {:limit_exceeded, :timeout, 20}} =
             VM.call(program, "render", [], handlers: %{"wait" => handler}, timeout: 20)

    assert_receive {:handler_started, handler_pid}
    monitor = Process.monitor(handler_pid)
    assert_receive {:DOWN, ^monitor, :process, ^handler_pid, _reason}, 1_000
  end

  test "charges external call arguments against logical memory limits" do
    assert {:ok, program} = VM.compile("function identity(value) { return value }")
    argument = String.duplicate("x", 8_192)

    assert {:ok, measurement} = VM.measure_call(program, "identity", [argument])
    assert measurement.result == {:ok, argument}
    limit = measurement.logical_memory_bytes - 1

    assert {:error, {:limit_exceeded, :memory_bytes, ^limit}} =
             VM.call(program, "identity", [argument], memory_limit: limit)
  end

  test "does not invoke the target after failed program initialization" do
    source = """
    globalThis.called = false;
    function render() { globalThis.called = true; return 42; }
    throw new Error("initialization failed");
    """

    assert {:ok, program} = VM.compile(source)

    assert {:error, %QuickBEAM.JSError{name: "Error", message: "initialization failed"}} =
             VM.call(program, "render")
  end
end
