defmodule QuickBEAM.VM.MemoryLimitTest do
  use ExUnit.Case, async: false

  test "validates the JavaScript allocation budget" do
    assert {:ok, program} = QuickBEAM.VM.compile("1")

    for limit <- [0, -1, "1 MB"] do
      assert {:error, {:invalid_option, :memory_limit, ^limit}} =
               QuickBEAM.VM.eval(program, memory_limit: limit)
    end

    assert {:ok, 1} = QuickBEAM.VM.eval(program, memory_limit: :infinity)
  end

  test "enforces the logical allocation budget in caller and isolated modes" do
    source = "{let values=[]; for(let i=0;i<1000;i++) values[i]={}; values.length}"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    for isolation <- [:caller, :process] do
      assert {:error, {:limit_exceeded, :memory_bytes, 20_000}} =
               QuickBEAM.VM.eval(program,
                 isolation: isolation,
                 memory_limit: 20_000,
                 max_steps: 100_000
               )
    end
  end

  test "memory limits cannot be intercepted by JavaScript catch handlers" do
    source = "try { let values=[]; while(true) values[values.length]={} } catch(error) { 42 }"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:error, {:limit_exceeded, :memory_bytes, 20_000}} =
             QuickBEAM.VM.eval(program, memory_limit: 20_000, max_steps: 100_000)
  end

  test "isolated workers receive a BEAM max-heap containment boundary" do
    assert [:monitor, {:max_heap_size, heap_limit}] =
             QuickBEAM.VM.worker_spawn_options(1_000_000)

    assert heap_limit.kill
    refute heap_limit.error_logger
    assert heap_limit.size > div(1_000_000, :erlang.system_info(:wordsize))
    assert QuickBEAM.VM.worker_spawn_options(:infinity) == [:monitor]
  end

  test "contains oversized host results and reclaims the evaluation owner" do
    test_process = self()
    source = "(async function(){return await Beam.call('large_result')})()"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    handler = fn [] ->
      {:links, links} = Process.info(self(), :links)
      send(test_process, {:handler_process, self(), links})
      Enum.to_list(1..5_000)
    end

    assert {:error, {:limit_exceeded, :memory_bytes, 20_000}} =
             QuickBEAM.VM.eval(program,
               handlers: %{"large_result" => handler},
               memory_limit: 20_000,
               timeout: 5_000
             )

    assert_receive {:handler_process, handler_pid, links}
    supervisor = Process.whereis(QuickBEAM.VM.TaskSupervisor)
    owner_pid = Enum.find(links, &(&1 != supervisor))

    refute Process.alive?(handler_pid)
    refute Process.alive?(owner_pid)
  end
end
