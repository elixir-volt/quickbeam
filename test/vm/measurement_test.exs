defmodule QuickBEAM.VM.MeasurementTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Measurement

  test "reports deterministic VM counters and endpoint process observations" do
    assert {:ok, program} = QuickBEAM.VM.compile("({answer: 40 + 2})")

    assert {:ok, %Measurement{} = first} = QuickBEAM.VM.measure(program)
    assert first.result == {:ok, %{"answer" => 42}}
    assert first.wall_time_us >= 0
    assert first.steps > 0
    assert first.logical_memory_bytes > 0
    assert first.process_memory_bytes > 0
    assert first.reductions > 0

    assert {:ok, %Measurement{} = second} = QuickBEAM.VM.measure(program)
    assert second.result == first.result
    assert second.steps == first.steps
    assert second.logical_memory_bytes == first.logical_memory_bytes
  end

  test "measures an asynchronously resumed evaluation" do
    assert {:ok, program} = QuickBEAM.VM.compile("Beam.call('double', 21)")
    handler = fn [value] -> value * 2 end

    assert {:ok, %Measurement{} = measurement} =
             QuickBEAM.VM.measure(program, handlers: %{"double" => handler})

    assert measurement.result == {:ok, 42}
    assert measurement.steps > 0
    assert measurement.logical_memory_bytes > 0
  end

  test "retains final counters for an interpreter resource rejection" do
    assert {:ok, program} = QuickBEAM.VM.compile("while (true) {}")

    assert {:ok, %Measurement{} = measurement} =
             QuickBEAM.VM.measure(program, max_steps: 100, timeout: 1_000)

    assert measurement.result == {:error, {:limit_exceeded, :steps, 100}}
    assert measurement.steps == 100
    assert measurement.logical_memory_bytes > 0
  end

  test "reports an outer timeout and terminates the outstanding handler" do
    parent = self()
    assert {:ok, program} = QuickBEAM.VM.compile("Beam.call('wait')")

    handler = fn [] ->
      send(parent, {:handler_started, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, %Measurement{} = measurement} =
             QuickBEAM.VM.measure(program,
               handlers: %{"wait" => handler},
               timeout: 200
             )

    assert measurement.result == {:error, {:limit_exceeded, :timeout, 200}}
    assert measurement.wall_time_us >= 200_000
    assert measurement.steps == nil
    assert measurement.logical_memory_bytes == nil

    assert_receive {:handler_started, handler_pid}
    monitor = Process.monitor(handler_pid)
    assert_receive {:DOWN, ^monitor, :process, ^handler_pid, _reason}, 1_000
  end

  test "returns validation errors before starting a measurement" do
    assert {:ok, program} = QuickBEAM.VM.compile("42")

    assert {:error, {:invalid_option, :max_steps, 0}} =
             QuickBEAM.VM.measure(program, max_steps: 0)
  end
end
