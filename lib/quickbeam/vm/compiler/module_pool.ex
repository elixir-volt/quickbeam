defmodule QuickBEAM.VM.Compiler.ModulePool do
  @moduledoc """
  Owns a bounded cache of generated BEAM modules.

  The pool leases fixed module atoms to evaluation processes, compiles each
  cache miss once, monitors lease owners, and reuses only idle slots. Backend
  installation and retirement are serialized in the pool process.
  """

  use GenServer

  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Compiler.ModulePool.Lease

  @default_compile_timeout 5_000
  @default_compile_max_heap_bytes 64 * 1024 * 1024
  @max_capacity Contract.pool_capacity()
  @max_skip_entries @max_capacity * 8

  @type server :: GenServer.server()

  @doc "Starts the singleton pool with a required `:backend` module."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {__MODULE__, opts} -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      {name, _opts} -> {:error, {:invalid_option, :name, name}}
    end
  end

  @doc "Checks out a compiled artifact, joining an existing compilation on a cache hit."
  @spec checkout(server(), binary(), term()) :: {:ok, Lease.t()} | {:error, term()}
  def checkout(server, key, input \\ nil) do
    if valid_key?(key) do
      GenServer.call(server, {:checkout, key, input}, :infinity)
    else
      {:error, {:invalid_artifact_key, key}}
    end
  end

  @doc "Checks out an already-ready artifact without starting compilation on a miss."
  @spec checkout_cached(server(), binary()) ::
          {:ok, Lease.t()} | :skip | :miss | {:error, term()}
  def checkout_cached(server, key) do
    if valid_key?(key) do
      GenServer.call(server, {:checkout_cached, key}, :infinity)
    else
      {:error, {:invalid_artifact_key, key}}
    end
  end

  @doc "Remembers a bounded negative lowering decision for a verified artifact key."
  @spec remember_skip(server(), binary()) :: :ok | {:error, term()}
  def remember_skip(server, key) do
    if valid_key?(key) do
      GenServer.call(server, {:remember_skip, key})
    else
      {:error, {:invalid_artifact_key, key}}
    end
  end

  @doc "Returns a lease after execution. Repeated or stale returns are rejected."
  @spec checkin(server(), Lease.t()) :: :ok | {:error, term()}
  def checkin(server, %Lease{} = lease),
    do: GenServer.call(server, {:checkin, lease, self()})

  @doc "Returns a freshly checked-out lease asynchronously after generated execution."
  @spec checkin_active(server(), Lease.t()) :: :ok | {:error, term()}
  def checkin_active(server, %Lease{owner: owner} = lease) when owner == self() do
    GenServer.cast(server, {:checkin_active, lease, self()})
    :ok
  end

  def checkin_active(_server, %Lease{}), do: {:error, :compiler_lease_owner_mismatch}

  @doc "Checks whether a lease is currently active for the calling process."
  @spec validate_lease(server(), Lease.t()) :: :ok | {:error, term()}
  def validate_lease(server, %Lease{} = lease),
    do: GenServer.call(server, {:validate_lease, lease, self()})

  @doc "Rejects new work, cancels compilation, and soft-retires slots after leases drain."
  @spec drain(server(), pos_integer()) :: :ok | {:error, term()}
  def drain(server, timeout \\ 5_000)

  def drain(server, timeout) when is_integer(timeout) and timeout > 0,
    do: GenServer.call(server, {:drain, timeout}, :infinity)

  def drain(_server, timeout), do: {:error, {:invalid_option, :drain_timeout, timeout}}

  @doc "Returns bounded diagnostic state for tests and operational inspection."
  @spec stats(server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    with {:ok, backend} <- fetch_backend(opts),
         {:ok, task_supervisor} <- fetch_task_supervisor(opts),
         {:ok, capacity} <- fetch_capacity(opts),
         {:ok, compile_timeout} <- fetch_compile_timeout(opts),
         {:ok, compile_max_heap_words} <- fetch_compile_max_heap_words(opts) do
      all_modules = Contract.pool_modules()
      initialized_slots = Map.new(all_modules, &{&1, initialize_slot(backend, &1)})
      modules = Enum.take(all_modules, capacity)
      slots = Map.take(initialized_slots, modules)

      {:ok,
       %{
         backend: backend,
         task_supervisor: task_supervisor,
         compile_timeout: compile_timeout,
         compile_max_heap_words: compile_max_heap_words,
         modules: modules,
         slots: slots,
         key_index: %{},
         skip_index: %{},
         leases: %{},
         monitor_index: %{},
         tasks: %{},
         epoch: System.unique_integer([:positive, :monotonic]),
         clock: 0,
         mode: :running,
         drain: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:checkout, _key, _input}, _from, %{mode: mode} = state)
      when mode != :running,
      do: {:reply, {:error, :compiler_pool_stopping}, state}

  def handle_call({:checkout, key, input}, from, state) do
    case Map.fetch(state.key_index, key) do
      {:ok, module} -> checkout_indexed(module, key, input, from, state)
      :error -> checkout_miss(key, input, from, state)
    end
  end

  def handle_call({:checkout_cached, _key}, _from, %{mode: mode} = state)
      when mode != :running,
      do: {:reply, {:error, :compiler_pool_stopping}, state}

  def handle_call({:checkout_cached, key}, from, state) do
    case Map.fetch(state.key_index, key) do
      {:ok, module} ->
        checkout_cached_indexed(module, key, from, state)

      :error ->
        if Map.has_key?(state.skip_index, key),
          do: {:reply, :skip, touch_skip(state, key)},
          else: {:reply, :miss, state}
    end
  end

  def handle_call({:remember_skip, _key}, _from, %{mode: mode} = state)
      when mode != :running,
      do: {:reply, {:error, :compiler_pool_stopping}, state}

  def handle_call({:remember_skip, key}, _from, state) do
    state = state |> put_skip(key) |> trim_skips()
    {:reply, :ok, state}
  end

  def handle_call({:checkin, lease, caller}, _from, state) do
    case fetch_lease(lease, caller, state) do
      {:ok, record} ->
        state = release_lease(lease.token, record, state, true)
        {:reply, :ok, maybe_complete_drain(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:validate_lease, lease, caller}, _from, state) do
    reply =
      case fetch_lease(lease, caller, state) do
        {:ok, _record} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:drain, _timeout}, _from, %{mode: mode} = state)
      when mode != :running,
      do: {:reply, {:error, :compiler_pool_stopping}, state}

  def handle_call({:drain, timeout}, from, state) do
    state = cancel_compilations(state)
    reference = make_ref()
    timer = Process.send_after(self(), {:drain_timeout, reference}, timeout)
    state = %{state | mode: :draining, drain: %{from: from, reference: reference, timer: timer}}
    {:noreply, maybe_complete_drain(state)}
  end

  def handle_call(:stats, _from, state) do
    counts = Enum.frequencies_by(state.slots, fn {_module, slot} -> slot.status end)

    slots =
      Enum.map(state.modules, fn module ->
        slot = Map.fetch!(state.slots, module)

        %{
          module: module,
          status: slot.status,
          key: Map.get(slot, :key),
          generation: slot.generation,
          lease_count: Map.get(slot, :lease_count, 0),
          reason: Map.get(slot, :reason)
        }
      end)

    {:reply,
     %{
       capacity: length(state.modules),
       epoch: state.epoch,
       counts: counts,
       leases: map_size(state.leases),
       compilations: map_size(state.tasks),
       skips: map_size(state.skip_index),
       mode: state.mode,
       slots: slots
     }, state}
  end

  @impl true
  def handle_cast({:checkin_active, lease, caller}, state) do
    state =
      case fetch_lease(lease, caller, state) do
        {:ok, record} -> release_lease(lease.token, record, state, true)
        {:error, _reason} -> state
      end

    {:noreply, maybe_complete_drain(state)}
  end

  @impl true
  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.fetch(state.tasks, reference) do
      {:ok, task_record} ->
        Process.demonitor(reference, [:flush])
        state = drop_task(reference, task_record, state)
        {:noreply, finish_compilation(task_record.module, result, state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:drain_timeout, reference}, %{drain: %{reference: reference}} = state) do
    GenServer.reply(
      state.drain.from,
      {:error, {:compiler_pool_shutdown_timeout, map_size(state.leases)}}
    )

    {:noreply, %{state | drain: nil}}
  end

  def handle_info({:drain_timeout, _reference}, state), do: {:noreply, state}

  def handle_info({:compile_timeout, reference}, state) do
    case Map.fetch(state.tasks, reference) do
      {:ok, task_record} ->
        Task.Supervisor.terminate_child(state.task_supervisor, task_record.pid)
        Process.demonitor(reference, [:flush])
        state = drop_task(reference, task_record, state)
        result = {:error, {:compile_timeout, state.compile_timeout}}
        {:noreply, finish_compilation(task_record.module, result, state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.tasks, reference) ->
        task_record = Map.fetch!(state.tasks, reference)
        state = drop_task(reference, task_record, state)
        result = {:error, {:compile_task_exit, reason}}
        {:noreply, finish_compilation(task_record.module, result, state)}

      Map.has_key?(state.monitor_index, reference) ->
        state = reference |> release_monitored_owner(state) |> maybe_complete_drain()
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_reference, task} ->
      Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    end)

    Enum.each(state.slots, fn {module, slot} ->
      if slot.status == :ready and slot.lease_count == 0 do
        safe_backend_call(state.backend, :retire, [module])
      end
    end)

    :ok
  end

  defp checkout_cached_indexed(module, key, from, state) do
    case Map.fetch!(state.slots, module) do
      %{status: :ready, key: ^key} ->
        {lease, state} = issue_lease(module, from, state)
        {:reply, {:ok, lease}, state}

      %{status: :compiling, key: ^key} ->
        state = add_waiter(module, from, state)
        {:noreply, state}

      _stale ->
        state = %{state | key_index: Map.delete(state.key_index, key)}
        {:reply, :miss, state}
    end
  end

  defp checkout_indexed(module, key, input, from, state) do
    case Map.fetch!(state.slots, module) do
      %{status: :ready, key: ^key} ->
        {lease, state} = issue_lease(module, from, state)
        {:reply, {:ok, lease}, state}

      %{status: :compiling, key: ^key} ->
        state = add_waiter(module, from, state)
        {:noreply, state}

      _stale ->
        state = %{state | key_index: Map.delete(state.key_index, key)}
        checkout_miss(key, input, from, state)
    end
  end

  defp checkout_miss(key, input, from, state) do
    case select_slot(state) do
      {:ok, module, :free} ->
        {:noreply, start_compilation(module, key, input, from, state)}

      {:ok, module, :evict} ->
        case retire_slot(module, state) do
          {:ok, state} ->
            {:noreply, start_compilation(module, key, input, from, state)}

          {:error, state} ->
            checkout_miss(key, input, from, state)
        end

      :error ->
        {:reply, {:error, :compiler_pool_busy}, state}
    end
  end

  defp select_slot(state) do
    case Enum.find(state.modules, &(Map.fetch!(state.slots, &1).status == :free)) do
      nil -> select_eviction(state)
      module -> {:ok, module, :free}
    end
  end

  defp select_eviction(state) do
    state.modules
    |> Enum.map(&Map.fetch!(state.slots, &1))
    |> Enum.filter(&(&1.status == :ready and &1.lease_count == 0))
    |> Enum.min_by(& &1.last_used, fn -> nil end)
    |> case do
      nil -> :error
      slot -> {:ok, slot.module, :evict}
    end
  end

  defp retire_slot(module, state) do
    slot = Map.fetch!(state.slots, module)
    state = %{state | key_index: Map.delete(state.key_index, slot.key)}

    case safe_backend_call(state.backend, :retire, [module]) do
      :ok ->
        {:ok, put_slot(state, free_slot(module, slot.generation))}

      result ->
        reason = backend_error(result)

        slot = %{
          module: module,
          status: :quarantined,
          generation: slot.generation,
          reason: reason
        }

        {:error, put_slot(state, slot)}
    end
  end

  defp start_compilation(module, key, input, from, state) do
    state = %{state | skip_index: Map.delete(state.skip_index, key)}
    {waiter, state} = monitor_waiter(module, from, state)
    backend = state.backend
    max_heap_words = state.compile_max_heap_words

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: max_heap_words,
          kill: true,
          error_logger: false
        })

        backend.compile(key, module, input)
      end)

    timer = Process.send_after(self(), {:compile_timeout, task.ref}, state.compile_timeout)
    previous = Map.fetch!(state.slots, module)

    slot = %{
      module: module,
      status: :compiling,
      key: key,
      generation: previous.generation,
      waiters: [waiter],
      task_ref: task.ref
    }

    task_record = %{module: module, pid: task.pid, timer: timer}

    state
    |> put_slot(slot)
    |> put_in([:key_index, key], module)
    |> put_in([:tasks, task.ref], task_record)
  end

  defp add_waiter(module, from, state) do
    {waiter, state} = monitor_waiter(module, from, state)
    update_slot(state, module, &Map.update!(&1, :waiters, fn waiters -> [waiter | waiters] end))
  end

  defp monitor_waiter(module, {owner, _tag} = from, state) do
    monitor = Process.monitor(owner)
    waiter = %{from: from, owner: owner, monitor: monitor}
    state = put_in(state, [:monitor_index, monitor], {:waiter, module})
    {waiter, state}
  end

  defp finish_compilation(module, {:ok, artifact}, state) do
    slot = Map.fetch!(state.slots, module)

    case safe_backend_call(state.backend, :install, [module, artifact]) do
      :ok -> compilation_ready(slot, state)
      result -> compilation_failed(slot, {:install_failed, backend_error(result)}, state, true)
    end
  end

  defp finish_compilation(module, {:error, reason}, state) do
    slot = Map.fetch!(state.slots, module)
    compilation_failed(slot, reason, state, false)
  end

  defp finish_compilation(module, result, state) do
    slot = Map.fetch!(state.slots, module)
    compilation_failed(slot, {:invalid_backend_result, result}, state, false)
  end

  defp compilation_ready(slot, state) do
    state = tick(state)

    ready = %{
      module: slot.module,
      status: :ready,
      key: slot.key,
      generation: slot.generation + 1,
      lease_count: 0,
      last_used: state.clock
    }

    state = put_slot(state, ready)

    Enum.reduce(Enum.reverse(slot.waiters), state, fn waiter, state ->
      state = demonitor_waiter(waiter, state)
      {lease, state} = issue_lease(slot.module, waiter.from, state)
      GenServer.reply(waiter.from, {:ok, lease})
      state
    end)
  end

  defp compilation_failed(slot, reason, state, quarantine?) do
    Enum.each(
      slot.waiters,
      &GenServer.reply(&1.from, {:error, {:compiler_compile_failed, reason}})
    )

    state = Enum.reduce(slot.waiters, state, &demonitor_waiter/2)
    state = %{state | key_index: Map.delete(state.key_index, slot.key)}

    replacement =
      if quarantine? do
        %{module: slot.module, status: :quarantined, generation: slot.generation, reason: reason}
      else
        free_slot(slot.module, slot.generation)
      end

    put_slot(state, replacement)
  end

  defp issue_lease(module, {owner, _tag}, state) do
    slot = Map.fetch!(state.slots, module)
    token = make_ref()
    monitor = Process.monitor(owner)

    lease = %Lease{
      pool: self(),
      module: module,
      key: slot.key,
      epoch: state.epoch,
      generation: slot.generation,
      token: token,
      owner: owner
    }

    record = %{module: module, owner: owner, monitor: monitor, lease: lease}

    state =
      state
      |> put_in([:leases, token], record)
      |> put_in([:monitor_index, monitor], {:lease, token})
      |> update_slot(module, &Map.update!(&1, :lease_count, fn count -> count + 1 end))
      |> touch_slot(module)

    {lease, state}
  end

  defp fetch_lease(%Lease{} = lease, caller, state) do
    with true <- lease.pool == self(),
         true <- lease.owner == caller,
         {:ok, record} <- Map.fetch(state.leases, lease.token),
         true <- record.lease == lease do
      {:ok, record}
    else
      false when lease.owner != caller -> {:error, :compiler_lease_owner_mismatch}
      _other -> {:error, :stale_compiler_lease}
    end
  end

  defp release_lease(token, record, state, demonitor?) do
    if demonitor?, do: Process.demonitor(record.monitor, [:flush])

    state
    |> update_in([:leases], &Map.delete(&1, token))
    |> update_in([:monitor_index], &Map.delete(&1, record.monitor))
    |> update_slot(record.module, &Map.update!(&1, :lease_count, fn count -> count - 1 end))
    |> touch_slot(record.module)
  end

  defp release_monitored_owner(reference, state) do
    case Map.fetch!(state.monitor_index, reference) do
      {:lease, token} ->
        record = Map.fetch!(state.leases, token)
        release_lease(token, record, state, false)

      {:waiter, module} ->
        state = update_in(state, [:monitor_index], &Map.delete(&1, reference))
        update_slot(state, module, &remove_waiter(&1, reference))
    end
  end

  defp remove_waiter(slot, reference) do
    waiters = Enum.reject(slot.waiters, &(&1.monitor == reference))
    %{slot | waiters: waiters}
  end

  defp demonitor_waiter(waiter, state) do
    Process.demonitor(waiter.monitor, [:flush])
    update_in(state, [:monitor_index], &Map.delete(&1, waiter.monitor))
  end

  defp drop_task(reference, task_record, state) do
    Process.cancel_timer(task_record.timer)
    update_in(state, [:tasks], &Map.delete(&1, reference))
  end

  defp touch_slot(state, module) do
    state = tick(state)
    update_slot(state, module, &Map.put(&1, :last_used, state.clock))
  end

  defp put_skip(state, key) do
    state = tick(state)
    put_in(state, [:skip_index, key], state.clock)
  end

  defp touch_skip(state, key), do: put_skip(state, key)

  defp trim_skips(state) when map_size(state.skip_index) <= @max_skip_entries, do: state

  defp trim_skips(state) do
    {key, _clock} = Enum.min_by(state.skip_index, fn {_key, clock} -> clock end)
    %{state | skip_index: Map.delete(state.skip_index, key)}
  end

  defp tick(state), do: %{state | clock: state.clock + 1}
  defp put_slot(state, slot), do: put_in(state, [:slots, slot.module], slot)
  defp update_slot(state, module, function), do: update_in(state, [:slots, module], function)

  defp free_slot(module, generation),
    do: %{module: module, status: :free, generation: generation}

  defp initialize_slot(backend, module) do
    case safe_backend_call(backend, :retire, [module]) do
      :ok ->
        free_slot(module, 0)

      result ->
        %{
          module: module,
          status: :quarantined,
          generation: 0,
          reason: backend_error(result)
        }
    end
  end

  defp safe_backend_call(backend, function, args) do
    apply(backend, function, args)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp backend_error({:error, reason}), do: reason
  defp backend_error(result), do: {:invalid_backend_result, result}

  defp cancel_compilations(state) do
    Enum.reduce(state.tasks, state, fn {reference, task_record}, state ->
      Task.Supervisor.terminate_child(state.task_supervisor, task_record.pid)
      Process.demonitor(reference, [:flush])
      state = drop_task(reference, task_record, state)
      finish_compilation(task_record.module, {:error, :compiler_pool_stopping}, state)
    end)
  end

  defp maybe_complete_drain(%{mode: :running} = state), do: state

  defp maybe_complete_drain(state) when map_size(state.leases) > 0 or map_size(state.tasks) > 0,
    do: state

  defp maybe_complete_drain(state) do
    {state, quarantined} = retire_ready_slots(state)

    response =
      if quarantined == [], do: :ok, else: {:error, {:compiler_slots_quarantined, quarantined}}

    case state.drain do
      nil ->
        %{state | mode: :drained}

      drain ->
        Process.cancel_timer(drain.timer)
        GenServer.reply(drain.from, response)
        %{state | mode: :drained, drain: nil}
    end
  end

  defp retire_ready_slots(state) do
    Enum.reduce(state.modules, {state, []}, fn module, {state, quarantined} ->
      slot = Map.fetch!(state.slots, module)
      retire_ready_slot(module, slot, state, quarantined)
    end)
  end

  defp retire_ready_slot(module, %{status: :ready, lease_count: 0} = slot, state, quarantined) do
    state = %{state | key_index: Map.delete(state.key_index, slot.key)}

    case safe_backend_call(state.backend, :retire, [module]) do
      :ok ->
        {put_slot(state, free_slot(module, slot.generation)), quarantined}

      result ->
        reason = backend_error(result)

        replacement = %{
          module: module,
          status: :quarantined,
          generation: slot.generation,
          reason: reason
        }

        {put_slot(state, replacement), [{module, reason} | quarantined]}
    end
  end

  defp retire_ready_slot(_module, _slot, state, quarantined), do: {state, quarantined}

  defp fetch_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} when is_atom(backend) ->
        if Code.ensure_loaded?(backend) and
             function_exported?(backend, :compile, 3) and
             function_exported?(backend, :install, 2) and
             function_exported?(backend, :retire, 1) do
          {:ok, backend}
        else
          {:error, {:invalid_compiler_backend, backend}}
        end

      {:ok, backend} ->
        {:error, {:invalid_compiler_backend, backend}}

      :error ->
        {:error, {:missing_option, :backend}}
    end
  end

  defp fetch_task_supervisor(opts) do
    supervisor = Keyword.get(opts, :task_supervisor, QuickBEAM.VM.TaskSupervisor)

    cond do
      is_pid(supervisor) and Process.alive?(supervisor) ->
        {:ok, supervisor}

      is_atom(supervisor) and is_pid(Process.whereis(supervisor)) ->
        {:ok, supervisor}

      is_atom(supervisor) or is_pid(supervisor) ->
        {:error, {:compiler_task_supervisor_unavailable, supervisor}}

      true ->
        {:error, {:invalid_option, :task_supervisor, supervisor}}
    end
  end

  defp fetch_capacity(opts) do
    case Keyword.get(opts, :capacity, Contract.pool_capacity()) do
      capacity when is_integer(capacity) and capacity > 0 and capacity <= @max_capacity ->
        {:ok, capacity}

      capacity ->
        {:error, {:invalid_option, :capacity, capacity}}
    end
  end

  defp fetch_compile_timeout(opts) do
    case Keyword.get(opts, :compile_timeout, @default_compile_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      timeout -> {:error, {:invalid_option, :compile_timeout, timeout}}
    end
  end

  defp fetch_compile_max_heap_words(opts) do
    bytes = Keyword.get(opts, :compile_max_heap_bytes, @default_compile_max_heap_bytes)

    if is_integer(bytes) and bytes > 0 do
      {:ok, max(div(bytes, :erlang.system_info(:wordsize)), 1)}
    else
      {:error, {:invalid_option, :compile_max_heap_bytes, bytes}}
    end
  end

  defp valid_key?(key),
    do: is_binary(key) and byte_size(key) == Contract.artifact_key_bytes()
end
