defmodule QuickBEAM.VM.ProgramStore.Lease do
  @moduledoc """
  Identifies one bounded lease on an immutable shared VM program.

  Leases contain only fixed-slot metadata. Program terms remain in
  `:persistent_term`; evaluation callers fetch a shared literal reference before
  spawning their workers.
  """

  @enforce_keys [:id, :key, :slot, :token]
  defstruct [:id, :key, :slot, :token]

  @type t :: %__MODULE__{
          id: reference(),
          key: binary(),
          slot: non_neg_integer(),
          token: reference()
        }
end

defmodule QuickBEAM.VM.ProgramStore do
  @moduledoc """
  Keeps a bounded set of large immutable VM programs in fixed persistent slots.

  The store exists to avoid copying a decoded program into every isolated
  evaluation process. Programs enter only through explicit `share_program/1`
  calls. The store never derives atoms from input, holds at most `capacity`
  persistent terms, and does not evict programs implicitly. Programs can be
  explicitly released; active leases defer erasure until their workers finish.
  """

  use GenServer

  alias QuickBEAM.VM.{Program, SharedProgram, Verifier}
  alias QuickBEAM.VM.ProgramStore.Lease

  @default_capacity 8
  @maximum_capacity 32
  @maximum_shared_bytecode_bytes 2 * 1024 * 1024
  @type checkout_result :: {:ok, Lease.t()} | :unavailable

  @doc "Starts the bounded shared-program store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stores a verified program explicitly and returns its lightweight handle."
  @spec share(Program.t(), GenServer.server()) ::
          {:ok, SharedProgram.t()} | :unavailable | {:error, :program_too_large}
  def share(program, server \\ __MODULE__)

  def share(
        %Program{share_key: key, bytecode_size: size} = program,
        server
      )
      when is_binary(key) and is_integer(size) and size <= @maximum_shared_bytecode_bytes do
    case reserve_and_install(key, program, server) do
      {:ok, lease} ->
        checkin(lease, server)
        {:ok, %SharedProgram{key: key}}

      :unavailable ->
        :unavailable
    end
  end

  def share(%Program{bytecode_size: size}, _server)
      when is_integer(size) and size > @maximum_shared_bytecode_bytes,
      do: {:error, :program_too_large}

  def share(%Program{}, _server), do: :unavailable

  @doc "Checks out an explicitly shared immutable program."
  @spec checkout(SharedProgram.t(), GenServer.server()) :: checkout_result()
  def checkout(%SharedProgram{key: key}, server \\ __MODULE__) do
    if GenServer.whereis(server),
      do: safe_store_call(server, {:checkout_existing, key}),
      else: :unavailable
  end

  @doc "Fetches the immutable program covered by an active lease."
  @spec fetch(Lease.t()) :: {:ok, Program.t()} | {:error, :stale_lease}
  def fetch(%Lease{key: key, slot: slot, token: token}) do
    case :persistent_term.get(storage_key(slot), :missing) do
      {^key, ^token, %Program{} = program} -> {:ok, program}
      _other -> {:error, :stale_lease}
    end
  end

  @doc "Returns a lease after its isolated evaluation has terminated."
  @spec checkin(Lease.t(), GenServer.server()) :: :ok
  def checkin(lease, server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, {:checkin, lease})
    :ok
  end

  @doc "Releases a program slot, deferring erasure while leases remain active."
  @spec release(Program.t() | SharedProgram.t(), GenServer.server()) :: :ok | :not_shared
  def release(program, server \\ __MODULE__)

  def release(%SharedProgram{key: key}, server), do: release_key(key, server)

  def release(%Program{share_key: key}, server) when is_binary(key),
    do: release_key(key, server)

  def release(%Program{}, _server), do: :not_shared

  defp release_key(key, server) do
    case GenServer.whereis(server) && safe_store_call(server, {:release, key}) do
      :ok -> :ok
      _unavailable -> :not_shared
    end
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    if not is_integer(capacity) or capacity <= 0 or capacity > @maximum_capacity do
      {:stop, {:invalid_capacity, capacity}}
    else
      {entries, slots} = restore_slots(capacity)

      {:ok,
       %{
         capacity: capacity,
         entries: entries,
         slots: slots,
         pending: %{}
       }}
    end
  end

  @impl true
  def handle_call({:checkout_existing, key}, from, state) do
    case state.entries do
      %{^key => entry} ->
        {lease, entry} = grant_lease(key, entry, from)
        {:reply, {:ok, lease}, put_in(state.entries[key], entry)}

      _entries ->
        {:reply, :unavailable, state}
    end
  end

  def handle_call({:reserve, key}, from, state) do
    case state.entries do
      %{^key => entry} ->
        {lease, entry} = grant_lease(key, entry, from)
        {:reply, {:ok, lease}, put_in(state.entries[key], entry)}

      _entries ->
        reserve_missing(key, from, state)
    end
  end

  def handle_call({:commit, key, token}, {owner, _tag}, state) do
    case state.pending do
      %{^key => %{owner: ^owner, token: ^token} = pending} ->
        if persisted?(pending.slot, key, token),
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

  def handle_call({:release, key}, _from, state) do
    case state.entries do
      %{^key => %{leases: leases} = entry} when map_size(leases) == 0 ->
        :persistent_term.erase(storage_key(entry.slot))
        {:reply, :ok, remove_entry(state, key, entry.slot)}

      %{^key => entry} ->
        {:reply, :ok, put_in(state.entries[key], %{entry | release?: true})}

      _entries ->
        {:reply, :not_shared, state}
    end
  end

  @impl true
  def handle_cast(
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

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.pending, fn {_key, pending} ->
           pending.monitor == monitor and pending.owner == owner
         end) do
      {key, pending} ->
        :persistent_term.erase(storage_key(pending.slot))
        Enum.each(pending.waiters, &GenServer.reply(&1, :unavailable))
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      nil ->
        {:noreply, drop_owner_lease(state, monitor)}
    end
  end

  defp reserve_and_install(key, program, server) do
    if GenServer.whereis(server) do
      case safe_store_call(server, {:reserve, key}) do
        {:install, token, slot} -> install_reserved(server, key, token, slot, program)
        result -> result
      end
    else
      :unavailable
    end
  end

  defp reserve_missing(key, from, state) do
    case state.pending do
      %{^key => pending} ->
        pending = %{pending | waiters: [from | pending.waiters]}
        {:noreply, put_in(state.pending[key], pending)}

      _pending ->
        case free_slot(state) do
          nil ->
            {:reply, :unavailable, state}

          slot ->
            owner = elem(from, 0)
            token = make_ref()

            pending = %{
              slot: slot,
              token: token,
              owner: owner,
              monitor: Process.monitor(owner),
              waiters: []
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

  defp restore_slots(capacity) do
    Enum.reduce(0..(capacity - 1), {%{}, %{}}, fn slot, {entries, slots} ->
      case :persistent_term.get(storage_key(slot), :missing) do
        {key, token, %Program{} = program} when is_binary(key) and is_reference(token) ->
          restore_program_slot(program, key, token, slot, entries, slots)

        :missing ->
          {entries, slots}

        _other ->
          :persistent_term.erase(storage_key(slot))
          {entries, slots}
      end
    end)
  end

  defp restore_program_slot(program, key, token, slot, entries, slots) do
    if Verifier.verify_identity(program) == :ok do
      entry = %{key: key, slot: slot, token: token, leases: %{}, release?: false}
      {Map.put(entries, key, entry), Map.put(slots, slot, key)}
    else
      :persistent_term.erase(storage_key(slot))
      {entries, slots}
    end
  end

  defp complete_install(key, token, owner, pending, state) do
    Process.demonitor(pending.monitor, [:flush])

    entry = %{
      key: key,
      slot: pending.slot,
      token: token,
      leases: %{},
      release?: false
    }

    {lease, entry} = grant_lease(key, entry, {owner, nil})

    entry =
      Enum.reduce(pending.waiters, entry, fn waiter, entry ->
        {waiter_lease, entry} = grant_lease(key, entry, waiter)
        GenServer.reply(waiter, {:ok, waiter_lease})
        entry
      end)

    state = %{
      state
      | entries: Map.put(state.entries, key, entry),
        slots: Map.put(state.slots, pending.slot, key),
        pending: Map.delete(state.pending, key)
    }

    {:reply, {:ok, lease}, state}
  end

  defp cancel_install(key, pending, state) do
    Process.demonitor(pending.monitor, [:flush])
    :persistent_term.erase(storage_key(pending.slot))
    Enum.each(pending.waiters, &GenServer.reply(&1, :unavailable))
    {:reply, :unavailable, %{state | pending: Map.delete(state.pending, key)}}
  end

  defp install_reserved(server, key, token, slot, program) do
    result =
      case persist_program(slot, key, token, program) do
        :ok -> safe_store_call(server, {:commit, key, token})
        :error -> safe_store_call(server, {:cancel, key, token})
      end

    case result do
      :unavailable -> recover_or_erase_install(server, slot, key, token)
      installed -> installed
    end
  end

  defp recover_or_erase_install(server, slot, key, token) do
    case safe_store_call(server, {:checkout_existing, key}) do
      {:ok, lease} ->
        {:ok, lease}

      :unavailable ->
        erase_if_owned(slot, key, token)
        :unavailable
    end
  end

  defp safe_store_call(server, message) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, _reason -> :unavailable
  end

  defp erase_if_owned(slot, key, token) do
    if persisted?(slot, key, token), do: :persistent_term.erase(storage_key(slot))
  end

  defp grant_lease(key, entry, {owner, _tag}) do
    id = make_ref()
    monitor = Process.monitor(owner)
    lease = %Lease{id: id, key: key, slot: entry.slot, token: entry.token}
    {lease, %{entry | leases: Map.put(entry.leases, id, monitor)}}
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
    if map_size(entry.leases) == 0 and entry.release? do
      :persistent_term.erase(storage_key(entry.slot))
      remove_entry(state, key, entry.slot)
    else
      put_in(state.entries[key], entry)
    end
  end

  defp remove_entry(state, key, slot) do
    %{state | entries: Map.delete(state.entries, key), slots: Map.delete(state.slots, slot)}
  end

  defp persisted?(slot, key, token) do
    match?({^key, ^token, %Program{}}, :persistent_term.get(storage_key(slot), :missing))
  end

  defp persist_program(slot, key, token, program) do
    :persistent_term.put(storage_key(slot), {key, token, program})
    :ok
  rescue
    _exception -> :error
  end

  defp storage_key(slot), do: {__MODULE__, slot}
end
