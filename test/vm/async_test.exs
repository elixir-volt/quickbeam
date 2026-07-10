defmodule QuickBEAM.VM.AsyncTest do
  use ExUnit.Case, async: true

  test "awaits an asynchronous BEAM handler without blocking the evaluation process" do
    source = "(async function(){return await Beam.call('double', 21)})()"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    handler = fn [value] ->
      Process.sleep(5)
      value * 2
    end

    assert {:ok, 42} = QuickBEAM.VM.eval(program, handlers: %{"double" => handler})
  end

  test "settles multiple in-flight handlers independently" do
    source = """
    (async function() {
      const slow = Beam.call("delay", 15, 4)
      const fast = Beam.call("delay", 0, 2)
      return (await slow) * 10 + await fast
    })()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    handler = fn [delay, value] ->
      Process.sleep(delay)
      value
    end

    assert {:ok, 42} = QuickBEAM.VM.eval(program, handlers: %{"delay" => handler})
  end

  test "aggregates concurrently running Beam.call Promises" do
    source = """
    (async function() {
      const values = await Promise.all([
        Beam.call("delay", 15, 40),
        Beam.call("delay", 0, 2)
      ])
      return values[0] + values[1]
    })()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    handler = fn [delay, value] ->
      Process.sleep(delay)
      value
    end

    assert {:ok, 42} = QuickBEAM.VM.eval(program, handlers: %{"delay" => handler})
  end

  test "resumes handler failures through JavaScript exception unwinding" do
    source = """
    (async function() {
      try {
        return await Beam.call("fail")
      } catch (error) {
        return 42
      }
    })()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    handler = fn [] -> raise "handler failed" end
    assert {:ok, 42} = QuickBEAM.VM.eval(program, handlers: %{"fail" => handler})
  end

  test "rejects unknown handlers as catchable JavaScript errors" do
    source = """
    (async function() {
      try {
        return await Beam.call("missing")
      } catch (error) {
        return 42
      }
    })()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 42} = QuickBEAM.VM.eval(program)
  end

  test "wall-clock timeout terminates an outstanding handler task" do
    test_process = self()
    source = "(async function(){return await Beam.call('wait')})()"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    handler = fn [] ->
      send(test_process, {:handler_started, self()})
      Process.sleep(:infinity)
    end

    assert {:error, {:limit_exceeded, :timeout, 100}} =
             QuickBEAM.VM.eval(program, handlers: %{"wait" => handler}, timeout: 100)

    assert_receive {:handler_started, handler_pid}
    monitor = Process.monitor(handler_pid)
    assert_receive {:DOWN, ^monitor, :process, ^handler_pid, _reason}, 1_000
  end

  test "validates handler names and arities before starting evaluation" do
    assert {:ok, program} = QuickBEAM.VM.compile("1")

    assert {:error, {:invalid_option, :handlers, _handlers}} =
             QuickBEAM.VM.eval(program, handlers: %{bad: fn -> :bad end})
  end
end
