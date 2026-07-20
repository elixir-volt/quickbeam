defmodule QuickBEAM.VM.Compiler.PoolTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Compiler.Pool

  defmodule FakeBackend do
    @moduledoc "Test backend that records compiler module-pool lifecycle calls."

    @behaviour QuickBEAM.VM.Compiler.Pool.Backend

    @state __MODULE__.State

    @doc "Returns the fake backend state process name."
    def state_name, do: @state

    @doc "Configures the next retirement result for one module."
    def put_retire_result(module, result) do
      Agent.update(@state, &put_in(&1, [:retire_results, module], result))
    end

    @doc "Returns the recorded fake backend state."
    def state, do: Agent.get(@state, & &1)

    @doc "Clears recorded calls without changing configured retirement results."
    def clear_calls do
      Agent.update(@state, fn state ->
        %{state | compiles: %{}, compile_modules: [], installs: [], retires: []}
      end)
    end

    @impl true
    def compile(key, module, {:block, test_pid}) do
      record_compile(key, module)
      send(test_pid, {:compile_started, key, module, self()})

      receive do
        {:complete_compilation, ^key, result} -> result
      end
    end

    def compile(key, module, {:sleep, milliseconds}) do
      record_compile(key, module)
      Process.sleep(milliseconds)
      {:ok, {:artifact, key}}
    end

    def compile(key, module, {:install_error, reason}) do
      record_compile(key, module)
      {:ok, {:install_error, reason}}
    end

    def compile(key, module, {:exit, reason}) do
      record_compile(key, module)
      exit(reason)
    end

    def compile(key, module, {:allocate, count}) do
      record_compile(key, module)
      {:ok, Enum.to_list(1..count)}
    end

    def compile(key, module, _input) do
      record_compile(key, module)
      {:ok, {:artifact, key}}
    end

    @impl true
    def install(module, {:install_error, reason}) do
      Agent.update(@state, &update_in(&1.installs, fn installs -> [module | installs] end))
      {:error, reason}
    end

    def install(module, _artifact) do
      Agent.update(@state, &update_in(&1.installs, fn installs -> [module | installs] end))
      :ok
    end

    @impl true
    def retire(module) do
      Agent.get_and_update(@state, fn state ->
        result = Map.get(state.retire_results, module, :ok)
        {result, update_in(state.retires, fn retires -> [module | retires] end)}
      end)
    end

    defp record_compile(key, module) do
      Agent.update(@state, fn state ->
        state
        |> update_in([:compiles, key], &((&1 || 0) + 1))
        |> update_in([:compile_modules], fn modules -> [module | modules] end)
      end)
    end
  end

  setup do
    initial_state = fn ->
      %{compiles: %{}, compile_modules: [], installs: [], retires: [], retire_results: %{}}
    end

    start_supervised!(%{
      id: FakeBackend.state_name(),
      start: {Agent, :start_link, [initial_state, [name: FakeBackend.state_name()]]}
    })

    :ok
  end

  test "joins concurrent cache misses into one supervised compilation" do
    pool = start_pool(capacity: 2)
    key = key(1)
    parent = self()

    owners =
      for _ <- 1..20 do
        spawn_link(fn ->
          result = Pool.checkout(pool, key, {:block, parent})
          send(parent, {:checkout_result, self(), result})

          receive do
            :release ->
              {:ok, lease} = result
              send(parent, {:checkin_result, self(), Pool.checkin(pool, lease)})
          end
        end)
      end

    assert_receive {:compile_started, ^key, module, compiler_pid}
    refute_receive {:compile_started, ^key, _module, _pid}, 20
    send(compiler_pid, {:complete_compilation, key, {:ok, {:artifact, key}}})

    results =
      for _ <- owners do
        assert_receive {:checkout_result, owner, {:ok, lease}}
        assert lease.owner == owner
        assert lease.module == module
        lease
      end

    assert MapSet.size(MapSet.new(results, & &1.token)) == 20
    assert FakeBackend.state().compiles[key] == 1
    assert Pool.stats(pool).leases == 20

    Enum.each(owners, &send(&1, :release))

    for owner <- owners do
      assert_receive {:checkin_result, ^owner, :ok}
    end

    assert eventually(fn -> Pool.stats(pool).leases == 0 end)
  end

  test "removes a dead single-flight waiter without creating an orphan lease" do
    pool = start_pool(capacity: 1)
    key = key(1)
    parent = self()

    waiter = spawn(fn -> Pool.checkout(pool, key, {:block, parent}) end)
    assert_receive {:compile_started, ^key, _module, compiler_pid}
    monitor = Process.monitor(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}

    send(compiler_pid, {:complete_compilation, key, {:ok, {:artifact, key}}})
    assert eventually(fn -> Pool.stats(pool).counts == %{ready: 1} end)
    assert Pool.stats(pool).leases == 0
    assert {:ok, lease} = Pool.checkout(pool, key)
    assert FakeBackend.state().compiles[key] == 1
    assert :ok = Pool.checkin(pool, lease)
  end

  test "probes warm artifacts without compiling on a miss" do
    pool = start_pool(capacity: 1)
    key = key(1)

    assert :miss = Pool.checkout_cached(pool, key)
    assert :ok = Pool.remember_skip(pool, key(2))
    assert :skip = Pool.checkout_cached(pool, key(2))
    assert Pool.stats(pool).skips == 1
    assert FakeBackend.state().compiles == %{}

    assert {:ok, cold_lease} = Pool.checkout(pool, key, :cold_input)
    assert :ok = Pool.checkin(pool, cold_lease)
    assert {:ok, warm_lease} = Pool.checkout_cached(pool, key)
    assert warm_lease.key == key
    assert FakeBackend.state().compiles[key] == 1
    assert :ok = Pool.checkin(pool, warm_lease)
  end

  test "bounds shared negative decisions without allocating key atoms" do
    pool = start_pool(capacity: 1)
    atom_count = :erlang.system_info(:atom_count)

    for id <- 1..300 do
      assert :ok = Pool.remember_skip(pool, key(id))
    end

    assert Pool.stats(pool).skips == 256
    assert :miss = Pool.checkout_cached(pool, key(1))
    assert :skip = Pool.checkout_cached(pool, key(300))
    assert :erlang.system_info(:atom_count) == atom_count
  end

  test "bounds shared region admission without allocating key atoms" do
    pool = start_pool(capacity: 1)
    atom_count = :erlang.system_info(:atom_count)

    assert :cold = Pool.admit_region(pool, key(1))
    assert :cold = Pool.admit_region(pool, key(1))
    assert :hot = Pool.admit_region(pool, key(1))
    assert :hot = Pool.admit_region(pool, key(1))

    for id <- 2..300 do
      assert :cold = Pool.admit_region(pool, key(id))
    end

    stats = Pool.stats(pool)
    assert stats.region_admissions == 256
    assert stats.region_hot == 1
    assert stats.region_hot_capacity == 1
    assert :hot = Pool.admit_region(pool, key(1))
    assert :cold = Pool.admit_region(pool, key(2))
    assert :cold = Pool.admit_region(pool, key(2))
    assert :cold = Pool.admit_region(pool, key(2))
    assert :erlang.system_info(:atom_count) == atom_count
  end

  @tag capture_log: true
  test "makes a slot reusable after a compiler task exits" do
    pool = start_pool(capacity: 1)

    assert {:error, {:compiler_compile_failed, {:compile_task_exit, :lowering_crash}}} =
             Pool.checkout(pool, key(1), {:exit, :lowering_crash})

    assert Pool.stats(pool).counts == %{free: 1}
    assert {:ok, _lease} = Pool.checkout(pool, key(2))
  end

  test "keeps cache modules within capacity while reusing slots by LRU" do
    pool = start_pool(capacity: 2)
    atom_count = :erlang.system_info(:atom_count)

    for id <- 1..100 do
      assert {:ok, lease} = Pool.checkout(pool, key(id))
      assert :ok = Pool.checkin(pool, lease)
    end

    stats = Pool.stats(pool)
    assert stats.capacity == 2
    assert stats.counts == %{ready: 2}
    assert Enum.all?(stats.slots, &(&1.module in Enum.take(Contract.pool_modules(), 2)))
    assert length(Enum.uniq(FakeBackend.state().compile_modules)) == 2
    assert length(FakeBackend.state().retires) == 98
    assert :erlang.system_info(:atom_count) == atom_count
  end

  test "does not evict an actively leased module" do
    pool = start_pool(capacity: 1)
    assert {:ok, lease} = Pool.checkout(pool, key(1))
    assert {:error, :compiler_pool_busy} = Pool.checkout(pool, key(2))
    assert :ok = Pool.validate_lease(pool, lease)
    assert :ok = Pool.checkin(pool, lease)
    assert {:ok, replacement} = Pool.checkout(pool, key(2))
    assert replacement.generation == lease.generation + 1
  end

  test "owner death automatically releases every lease" do
    pool = start_pool(capacity: 1)
    parent = self()

    owner =
      spawn(fn ->
        result = Pool.checkout(pool, key(1))
        send(parent, {:owner_checkout, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_checkout, ^owner, {:ok, lease}}
    assert Pool.stats(pool).leases == 1
    Process.exit(owner, :kill)

    assert eventually(fn -> Pool.stats(pool).leases == 0 end)
    assert {:error, :compiler_lease_owner_mismatch} = Pool.validate_lease(pool, lease)
    assert {:ok, replacement} = Pool.checkout(pool, key(2))
    assert replacement.module == lease.module
  end

  test "rejects stale and cross-owner leases" do
    pool = start_pool(capacity: 1)
    assert {:ok, first} = Pool.checkout(pool, key(1))

    task = Task.async(fn -> Pool.validate_lease(pool, first) end)
    assert {:error, :compiler_lease_owner_mismatch} = Task.await(task)

    assert :ok = Pool.checkin(pool, first)
    assert {:ok, second} = Pool.checkout(pool, key(2))
    assert second.generation > first.generation
    assert {:error, :stale_compiler_lease} = Pool.validate_lease(pool, first)
    assert {:error, :stale_compiler_lease} = Pool.checkin(pool, first)
  end

  test "pool restart changes epoch and rejects every old lease" do
    name = Pool
    pool = start_pool(capacity: 1)
    assert {:ok, lease} = Pool.checkout(pool, key(1))
    first_epoch = Pool.stats(pool).epoch

    FakeBackend.put_retire_result(lease.module, {:error, :live_code_reference})
    GenServer.stop(pool, :shutdown)

    assert eventually(fn -> is_pid(Process.whereis(name)) and Process.whereis(name) != pool end)
    restarted = Process.whereis(name)
    refute Pool.stats(restarted).epoch == first_epoch
    assert {:error, :stale_compiler_lease} = Pool.validate_lease(restarted, lease)

    assert [%{status: :quarantined, reason: :live_code_reference}] =
             Pool.stats(restarted).slots
  end

  test "quarantines a slot when soft retirement fails" do
    pool = start_pool(capacity: 1)
    assert {:ok, lease} = Pool.checkout(pool, key(1))
    assert :ok = Pool.checkin(pool, lease)
    FakeBackend.put_retire_result(lease.module, {:error, :live_code_reference})

    assert {:error, :compiler_pool_busy} = Pool.checkout(pool, key(2))

    assert [%{status: :quarantined, reason: :live_code_reference}] =
             Pool.stats(pool).slots

    assert FakeBackend.state().retires == [lease.module]
  end

  @tag capture_log: true
  test "contains a compiler task that exceeds its BEAM heap ceiling" do
    pool = start_pool(capacity: 1, compile_max_heap_bytes: 128 * 1024)

    assert {:error, {:compiler_compile_failed, {:compile_task_exit, :killed}}} =
             Pool.checkout(pool, key(1), {:allocate, 1_000_000})

    assert Pool.stats(pool).counts == %{free: 1}
    assert {:ok, _lease} = Pool.checkout(pool, key(2))
  end

  test "bounds compilation time and makes the uninstalled slot reusable" do
    pool = start_pool(capacity: 1, compile_timeout: 20)
    key = key(1)
    parent = self()

    task = Task.async(fn -> Pool.checkout(pool, key, {:block, parent}) end)
    assert_receive {:compile_started, ^key, _module, compiler_pid}

    assert {:error, {:compiler_compile_failed, {:compile_timeout, 20}}} = Task.await(task)
    refute Process.alive?(compiler_pid)
    assert Pool.stats(pool).counts == %{free: 1}
    assert {:ok, _lease} = Pool.checkout(pool, key(2))
  end

  test "quarantines a slot after an installation failure" do
    pool = start_pool(capacity: 1)

    assert {:error, {:compiler_compile_failed, {:install_failed, :bad_beam}}} =
             Pool.checkout(pool, key(1), {:install_error, :bad_beam})

    assert [%{status: :quarantined, reason: {:install_failed, :bad_beam}}] =
             Pool.stats(pool).slots

    assert {:error, :compiler_pool_busy} = Pool.checkout(pool, key(2))
  end

  test "drain cancels supervised compilation and rejects its waiters" do
    pool = start_pool(capacity: 1)
    key = key(1)
    parent = self()
    waiter = Task.async(fn -> Pool.checkout(pool, key, {:block, parent}) end)
    assert_receive {:compile_started, ^key, _module, compiler_pid}

    assert :ok = Pool.drain(pool, 1_000)
    assert {:error, {:compiler_compile_failed, :compiler_pool_stopping}} = Task.await(waiter)
    refute Process.alive?(compiler_pid)
    assert Pool.stats(pool).mode == :drained
    assert Pool.stats(pool).counts == %{free: 1}
  end

  test "drains active owners before retiring modules and rejects new work" do
    pool = start_pool(capacity: 1)
    assert {:ok, lease} = Pool.checkout(pool, key(1))

    drain = Task.async(fn -> Pool.drain(pool, 1_000) end)
    assert eventually(fn -> Pool.stats(pool).mode == :draining end)
    assert {:error, :compiler_pool_stopping} = Pool.checkout(pool, key(2))
    refute Task.yield(drain, 20)

    assert :ok = Pool.checkin(pool, lease)
    assert :ok = Task.await(drain)
    assert Pool.stats(pool).mode == :drained
    assert Pool.stats(pool).counts == %{free: 1}
    assert FakeBackend.state().retires == [lease.module]
  end

  test "bounds shutdown waiting without hard-purging an active slot" do
    pool = start_pool(capacity: 1)
    assert {:ok, lease} = Pool.checkout(pool, key(1))

    assert {:error, {:compiler_pool_shutdown_timeout, 1}} = Pool.drain(pool, 20)
    assert FakeBackend.state().retires == []
    assert Pool.stats(pool).mode == :draining

    assert :ok = Pool.checkin(pool, lease)
    assert eventually(fn -> Pool.stats(pool).mode == :drained end)
    assert FakeBackend.state().retires == [lease.module]
  end

  test "soft-retires every reserved module name before admitting work" do
    pool =
      start_supervised!(
        {Pool, backend: FakeBackend, task_supervisor: QuickBEAM.VM.TaskSupervisor, capacity: 1}
      )

    assert Process.alive?(pool)
    assert Enum.sort(FakeBackend.state().retires) == Enum.sort(Contract.pool_modules())
    assert Pool.stats(pool).counts == %{free: 1}
  end

  test "enforces one process-wide owner for the static module names" do
    pool = start_pool(capacity: 1)

    assert {:error, {:already_started, ^pool}} =
             Pool.start_link(backend: FakeBackend, capacity: 1)

    assert {:error, {:invalid_option, :name, :another_pool}} =
             Pool.start_link(backend: FakeBackend, name: :another_pool)
  end

  test "validates bounded startup options and artifact keys" do
    assert {:error, {:invalid_artifact_key, <<1>>}} =
             Pool.checkout(self(), <<1>>)

    assert {:error, {{:missing_option, :backend}, _child}} =
             start_supervised({Pool, []})

    assert {:error, {{:invalid_compiler_backend, String}, _child}} =
             start_supervised({Pool, backend: String})

    assert {:error, {{:invalid_option, :capacity, 33}, _child}} =
             start_supervised({Pool, backend: FakeBackend, capacity: 33})

    assert {:error, {{:invalid_option, :compile_timeout, 0}, _child}} =
             start_supervised({Pool, backend: FakeBackend, compile_timeout: 0})

    assert {:error, {{:invalid_option, :compile_max_heap_bytes, 0}, _child}} =
             start_supervised({Pool, backend: FakeBackend, compile_max_heap_bytes: 0})
  end

  defp start_pool(opts) do
    pool =
      start_supervised!(
        {Pool,
         Keyword.merge(
           [backend: FakeBackend, task_supervisor: QuickBEAM.VM.TaskSupervisor],
           opts
         )}
      )

    FakeBackend.clear_calls()
    pool
  end

  defp key(integer), do: :crypto.hash(:sha256, <<integer::unsigned-64>>)

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: function.()

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(5)
      eventually(function, attempts - 1)
    end
  end
end
