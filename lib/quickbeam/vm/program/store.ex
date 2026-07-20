defmodule QuickBEAM.VM.Program.Store do
  @moduledoc """
  Keeps a bounded set of large immutable VM programs in fixed persistent slots.

  The store exists to avoid copying a decoded program into every isolated
  evaluation process. Programs enter only through explicit `pin/1`
  calls. The store never derives atoms from input, holds at most `capacity`
  persistent terms, bounds both per-program and total external-term residency,
  and does not evict programs implicitly. Programs can be
  explicitly released; active leases defer erasure until their workers finish.

  Persistent slots are namespaced by the store's registered name, so a
  supervised store restarts with its own capacity and never restores slots
  written under a different store name.
  """

  use GenServer

  alias QuickBEAM.VM.Bytecode.Verifier
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Program.Pinned
  alias QuickBEAM.VM.Program.Store.Lease

  @default_capacity 8
  @maximum_capacity 32
  @maximum_pinned_bytecode_bytes 2 * 1024 * 1024
  @maximum_program_residency_bytes 32 * 1024 * 1024
  @maximum_total_residency_bytes 128 * 1024 * 1024
  @type checkout_result :: {:ok, Lease.t()} | :unavailable

  @doc "Starts the bounded pinned-program store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc "Pins a verified program explicitly and returns its lightweight handle."
  @spec pin(Program.t(), GenServer.server()) ::
          {:ok, Pinned.t()}
          | :unavailable
          | :retiring
          | {:error, :program_too_large | :residency_budget}
  def pin(program, server \\ __MODULE__)

  def pin(
        %Program{pin_key: key, bytecode_size: size} = program,
        server
      )
      when is_binary(key) and is_integer(size) and size <= @maximum_pinned_bytecode_bytes do
    case program_residency(program) do
      {:ok, residency_bytes} when residency_bytes <= @maximum_program_residency_bytes ->
        case reserve_and_install(key, program, residency_bytes, server) do
          {:ok, lease} ->
            checkin(lease, server)
            {:ok, %Pinned{key: key}}

          result ->
            result
        end

      _oversized_or_invalid ->
        {:error, :program_too_large}
    end
  end

  def pin(%Program{bytecode_size: size}, _server)
      when is_integer(size) and size > @maximum_pinned_bytecode_bytes,
      do: {:error, :program_too_large}

  def pin(%Program{}, _server), do: :unavailable

  @doc "Checks out an explicitly pinned immutable program."
  @spec checkout(Pinned.t(), GenServer.server()) :: checkout_result()
  def checkout(%Pinned{key: key}, server \\ __MODULE__) do
    if GenServer.whereis(server),
      do: safe_store_call(server, {:checkout_existing, key}),
      else: :unavailable
  end

  @doc "Fetches the immutable program covered by an active lease."
  @spec fetch(Lease.t()) :: {:ok, Program.t()} | {:error, :stale_lease}
  def fetch(%Lease{key: key, slot: slot, token: token, store: store}) do
    case :persistent_term.get(storage_key(store, slot), :missing) do
      {^key, ^token, %Program{} = program} -> {:ok, program}
      _other -> {:error, :stale_lease}
    end
  end

  @doc "Returns a lease after its isolated evaluation has terminated."
  @spec checkin(Lease.t(), GenServer.server()) :: :ok
  def checkin(%Lease{} = lease, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> send(pid, {:checkin, lease})
    end

    :ok
  end

  @doc "Unpins a program slot, deferring erasure while leases remain active."
  @spec unpin(Program.t() | Pinned.t(), GenServer.server()) :: :ok | :not_pinned
  def unpin(program, server \\ __MODULE__)

  def unpin(%Pinned{key: key}, server), do: unpin_key(key, server)

  def unpin(%Program{pin_key: key}, server) when is_binary(key),
    do: unpin_key(key, server)

  def unpin(%Program{}, _server), do: :not_pinned

  defp unpin_key(key, server) do
    case GenServer.whereis(server) && safe_store_call(server, {:unpin, key}) do
      :ok -> :ok
      _unavailable -> :not_pinned
    end
  end

  @impl true
  def init({name, opts}) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    if not is_integer(capacity) or capacity <= 0 or capacity > @maximum_capacity do
      {:stop, {:invalid_capacity, capacity}}
    else
      {entries, slots, residency_bytes} = restore_slots(name, capacity)

      {:ok,
       %{
         name: name,
         capacity: capacity,
         entries: entries,
         slots: slots,
         pending: %{},
         residency_bytes: residency_bytes
       }}
    end
  end

  @impl true
  def handle_call({:checkout_existing, key}, from, state) do
    case state.entries do
      %{^key => %{unpin?: true}} ->
        {:reply, :unavailable, state}

      %{^key => entry} ->
        {lease, entry} = grant_lease(state, key, entry, from)
        {:reply, {:ok, lease}, put_in(state.entries[key], entry)}

      _entries ->
        {:reply, :unavailable, state}
    end
  end

  def handle_call({:reserve, key, residency_bytes}, from, state) do
    case state.entries do
      %{^key => %{unpin?: true}} ->
        {:reply, :retiring, state}

      %{^key => entry} ->
        {lease, entry} = grant_lease(state, key, entry, from)
        {:reply, {:ok, lease}, put_in(state.entries[key], entry)}

      _entries ->
        reserve_missing(key, residency_bytes, from, state)
    end
  end

  def handle_call({:commit, key, token}, {owner, _tag}, state) do
    case state.pending do
      %{^key => %{owner: ^owner, token: ^token} = pending} ->
        if persisted?(state.name, pending.slot, key, token),
          do: complete_install(key, token, owner, pending, state),
          else: cancel_install(key, pending, state)

      _pending ->
        {:reply, :unavailable, state}
    end
  end

  def handle_call({:cancel, key, token}, {owner, _tag}, state) do
    case state.pending do
      %{^key => %{owner: ^owner, token: ^token} = pending} ->
        cancel_install(key, pending, state)

      _pending ->
        {:reply, :unavailable, state}
    end
  end

  def handle_call({:unpin, key}, _from, state) do
    case state.entries do
      %{^key => %{leases: leases} = entry} when map_size(leases) == 0 ->
        :persistent_term.erase(storage_key(state.name, entry.slot))
        {:reply, :ok, remove_entry(state, key, entry.slot)}

      %{^key => entry} ->
        {:reply, :ok, put_in(state.entries[key], %{entry | unpin?: true})}

      _entries ->
        {:reply, :not_pinned, state}
    end
  end

  @impl true
  def handle_info(
        {:checkin, %Lease{id: id, key: key, slot: slot, token: token}},
        state
      ) do
    case state.entries do
      %{^key => %{slot: ^slot, token: ^token, leases: %{^id => monitor}} = entry} ->
        Process.demonitor(monitor, [:flush])
        entry = %{entry | leases: Map.delete(entry.leases, id)}
        {:noreply, maybe_release_entry(state, key, entry)}

      _entries ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.pending, fn {_key, pending} ->
           pending.monitor == monitor and pending.owner == owner
         end) do
      {key, pending} ->
        :persistent_term.erase(storage_key(state.name, pending.slot))
        Enum.each(pending.waiters, &GenServer.reply(&1, :unavailable))
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      nil ->
        {:noreply, drop_owner_lease(state, monitor)}
    end
  end

  defp reserve_and_install(key, program, residency_bytes, server) do
    if GenServer.whereis(server) do
      case safe_store_call(server, {:reserve, key, residency_bytes}) do
        {:install, token, slot} -> install_reserved(server, key, token, slot, program)
        result -> result
      end
    else
      :unavailable
    end
  end

  defp reserve_missing(key, residency_bytes, from, state) do
    case state.pending do
      %{^key => pending} ->
        pending = %{pending | waiters: [from | pending.waiters]}
        {:noreply, put_in(state.pending[key], pending)}

      _pending ->
        case {free_slot(state), residency_available?(state, residency_bytes)} do
          {nil, _available?} ->
            {:reply, :unavailable, state}

          {_slot, false} ->
            {:reply, {:error, :residency_budget}, state}

          {slot, true} ->
            owner = elem(from, 0)
            token = make_ref()

            pending = %{
              slot: slot,
              token: token,
              owner: owner,
              monitor: Process.monitor(owner),
              waiters: [],
              residency_bytes: residency_bytes
            }

            {:reply, {:install, token, slot}, put_in(state.pending[key], pending)}
        end
    end
  end

  defp free_slot(state) do
    pending_slots = MapSet.new(state.pending, fn {_key, pending} -> pending.slot end)

    Enum.find(0..(state.capacity - 1), fn slot ->
      not Map.has_key?(state.slots, slot) and not MapSet.member?(pending_slots, slot)
    end)
  end

  defp program_residency(program) do
    {:ok, :erlang.external_size(program)}
  rescue
    _exception -> :error
  end

  defp residency_available?(state, residency_bytes) do
    pending_bytes =
      Enum.reduce(state.pending, 0, fn {_key, pending}, total ->
        total + pending.residency_bytes
      end)

    state.residency_bytes + pending_bytes + residency_bytes <=
      @maximum_total_residency_bytes
  end

  defp restore_slots(name, capacity) do
    Enum.reduce(0..(capacity - 1), {%{}, %{}, 0}, fn slot, {entries, slots, residency_bytes} ->
      case :persistent_term.get(storage_key(name, slot), :missing) do
        {key, token, %Program{} = program} when is_binary(key) and is_reference(token) ->
          restore_program_slot(
            name,
            program,
            key,
            token,
            slot,
            entries,
            slots,
            residency_bytes
          )

        :missing ->
          {entries, slots, residency_bytes}

        _other ->
          :persistent_term.erase(storage_key(name, slot))
          {entries, slots, residency_bytes}
      end
    end)
  end

  defp restore_program_slot(name, program, key, token, slot, entries, slots, total_bytes) do
    with :ok <- Verifier.verify_identity(program),
         {:ok, program_bytes} <- program_residency(program),
         true <- program_bytes <= @maximum_program_residency_bytes,
         true <- total_bytes + program_bytes <= @maximum_total_residency_bytes do
      entry = %{
        key: key,
        slot: slot,
        token: token,
        leases: %{},
        unpin?: false,
        residency_bytes: program_bytes
      }

      {Map.put(entries, key, entry), Map.put(slots, slot, key), total_bytes + program_bytes}
    else
      _invalid_or_oversized ->
        :persistent_term.erase(storage_key(name, slot))
        {entries, slots, total_bytes}
    end
  end

  defp complete_install(key, token, owner, pending, state) do
    Process.demonitor(pending.monitor, [:flush])

    entry = %{
      key: key,
      slot: pending.slot,
      token: token,
      leases: %{},
      unpin?: false,
      residency_bytes: pending.residency_bytes
    }

    {lease, entry} = grant_lease(state, key, entry, {owner, nil})

    entry =
      Enum.reduce(pending.waiters, entry, fn waiter, entry ->
        {waiter_lease, entry} = grant_lease(state, key, entry, waiter)
        GenServer.reply(waiter, {:ok, waiter_lease})
        entry
      end)

    state = %{
      state
      | entries: Map.put(state.entries, key, entry),
        slots: Map.put(state.slots, pending.slot, key),
        pending: Map.delete(state.pending, key),
        residency_bytes: state.residency_bytes + pending.residency_bytes
    }

    {:reply, {:ok, lease}, state}
  end

  defp cancel_install(key, pending, state) do
    Process.demonitor(pending.monitor, [:flush])
    :persistent_term.erase(storage_key(state.name, pending.slot))
    Enum.each(pending.waiters, &GenServer.reply(&1, :unavailable))
    {:reply, :unavailable, %{state | pending: Map.delete(state.pending, key)}}
  end

  defp install_reserved(server, key, token, slot, program) do
    name = store_name(server)

    result =
      case persist_program(name, slot, key, token, program) do
        :ok -> safe_store_call(server, {:commit, key, token})
        :error -> safe_store_call(server, {:cancel, key, token})
      end

    case result do
      :unavailable -> recover_or_erase_install(server, name, slot, key, token)
      installed -> installed
    end
  end

  defp recover_or_erase_install(server, name, slot, key, token) do
    case safe_store_call(server, {:checkout_existing, key}) do
      {:ok, lease} ->
        {:ok, lease}

      :unavailable ->
        erase_if_owned(name, slot, key, token)
        :unavailable
    end
  end

  defp safe_store_call(server, message) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, _reason -> :unavailable
  end

  defp erase_if_owned(name, slot, key, token) do
    if persisted?(name, slot, key, token),
      do: :persistent_term.erase(storage_key(name, slot))
  end

  # Engine evaluations check in from the process that owns the lease, so the
  # store skips its own monitor there: that process either sends `{:checkin,
  # lease}` or dies, and its death is the only event the monitor would report.
  # Direct store users get a caller-from monitor so owner death completes
  # deferred unpinning.
  defp grant_lease(state, key, entry, {owner, _tag}) do
    id = make_ref()

    lease = %Lease{
      id: id,
      key: key,
      slot: entry.slot,
      token: entry.token,
      store: state.name
    }

    {lease, %{entry | leases: Map.put(entry.leases, id, Process.monitor(owner))}}
  end

  defp drop_owner_lease(state, monitor) do
    case owner_lease(state.entries, monitor) do
      {key, id, entry} ->
        entry = %{entry | leases: Map.delete(entry.leases, id)}
        maybe_release_entry(state, key, entry)

      nil ->
        state
    end
  end

  defp owner_lease(entries, monitor) do
    entries
    |> Enum.flat_map(fn {key, entry} ->
      Enum.map(entry.leases, fn {id, lease_monitor} -> {key, id, entry, lease_monitor} end)
    end)
    |> Enum.find_value(fn
      {key, id, entry, ^monitor} -> {key, id, entry}
      _lease -> nil
    end)
  end

  defp maybe_release_entry(state, key, entry) do
    if map_size(entry.leases) == 0 and entry.unpin? do
      :persistent_term.erase(storage_key(state.name, entry.slot))
      remove_entry(state, key, entry.slot)
    else
      put_in(state.entries[key], entry)
    end
  end

  defp remove_entry(state, key, slot) do
    entry = Map.fetch!(state.entries, key)

    %{
      state
      | entries: Map.delete(state.entries, key),
        slots: Map.delete(state.slots, slot),
        residency_bytes: state.residency_bytes - entry.residency_bytes
    }
  end

  defp persisted?(name, slot, key, token) do
    match?({^key, ^token, %Program{}}, :persistent_term.get(storage_key(name, slot), :missing))
  end

  defp persist_program(name, slot, key, token, program) do
    :persistent_term.put(storage_key(name, slot), {key, token, program})
    :ok
  rescue
    _exception -> :error
  end

  defp store_name(server) when is_atom(server), do: server

  defp store_name(server) when is_pid(server) do
    case Process.info(server, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] -> name
      _other -> server
    end
  end

  defp storage_key(name, slot), do: {__MODULE__, name, slot}
end
