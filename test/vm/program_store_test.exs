defmodule QuickBEAM.VM.ProgramStoreTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.ProgramStore

  test "coalesces concurrent first pin admission by program identity" do
    program = program(:crypto.strong_rand_bytes(32))

    pinned =
      1..20
      |> Task.async_stream(fn _index -> ProgramStore.pin(program) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, pinned}} -> pinned end)

    assert length(Enum.uniq(pinned)) == 1
    [handle | _rest] = pinned
    assert {:ok, lease} = ProgramStore.checkout(handle)
    assert {:ok, ^program} = ProgramStore.fetch(lease)
    ProgramStore.checkin(lease)
    assert :ok = ProgramStore.unpin(handle)
    assert eventually(fn -> ProgramStore.unpin(handle) == :not_pinned end)
  end

  test "pins one immutable program under concurrent bounded leases" do
    program = program(:crypto.strong_rand_bytes(32))

    assert {:ok, pinned} = ProgramStore.pin(program)
    parent = self()

    tasks =
      Enum.map(1..20, fn _index ->
        Task.async(fn ->
          {:ok, lease} = ProgramStore.checkout(pinned)
          send(parent, {:lease, lease})

          receive do
            :finish -> ProgramStore.checkin(lease)
          end
        end)
      end)

    leases =
      Enum.map(tasks, fn _task ->
        receive do
          {:lease, lease} -> lease
        end
      end)

    assert Enum.uniq_by(leases, &{&1.slot, &1.token}) |> length() == 1
    assert Enum.all?(leases, fn lease -> ProgramStore.fetch(lease) == {:ok, program} end)
    assert :ok = ProgramStore.unpin(pinned)
    assert Enum.all?(leases, fn lease -> ProgramStore.fetch(lease) == {:ok, program} end)

    Enum.each(tasks, &send(&1.pid, :finish))
    Enum.each(tasks, &Task.await/1)
    assert eventually(fn -> ProgramStore.unpin(pinned) == :not_pinned end)
    assert Enum.all?(leases, fn lease -> ProgramStore.fetch(lease) == {:error, :stale_lease} end)
  end

  test "restores fixed persistent slots after the store restarts" do
    program = program(:crypto.strong_rand_bytes(32))
    assert {:ok, pinned} = ProgramStore.pin(program)

    old_store = Process.whereis(ProgramStore)
    monitor = Process.monitor(old_store)
    Process.exit(old_store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_store, :killed}
    assert eventually(fn -> is_pid(Process.whereis(ProgramStore)) end)

    assert {:ok, lease} = ProgramStore.checkout(pinned)
    assert {:ok, ^program} = ProgramStore.fetch(lease)
    ProgramStore.checkin(lease)
    assert :ok = ProgramStore.unpin(pinned)
  end

  test "rejects programs above the bounded pinned bytecode size" do
    program = %{program(:crypto.strong_rand_bytes(32)) | bytecode_size: 2 * 1024 * 1024 + 1}
    assert {:error, :program_too_large} = ProgramStore.pin(program)
    assert :not_pinned = ProgramStore.unpin(program)
  end

  test "rejects decoded programs above the per-program residency bound" do
    oversized = :binary.copy(<<0>>, 33 * 1024 * 1024)
    program = %{program(:crypto.strong_rand_bytes(32)) | root: oversized}

    assert {:error, :program_too_large} = ProgramStore.pin(program)
    assert :not_pinned = ProgramStore.unpin(program)
  end

  test "rejects admission above the total decoded residency budget" do
    payload = :binary.copy(<<0>>, 27 * 1024 * 1024)

    pinned =
      Enum.map(1..4, fn _index ->
        candidate = %{program(:crypto.strong_rand_bytes(32)) | root: payload}
        assert {:ok, pinned} = ProgramStore.pin(candidate)
        pinned
      end)

    on_exit(fn -> Enum.each(pinned, &ProgramStore.unpin/1) end)

    candidate = %{program(:crypto.strong_rand_bytes(32)) | root: payload}
    assert {:error, :residency_budget} = ProgramStore.pin(candidate)
  end

  test "rejects a ninth pinned program without evicting fixed slots" do
    pinned =
      Enum.map(1..8, fn _index ->
        assert {:ok, pinned} = ProgramStore.pin(program(:crypto.strong_rand_bytes(32)))
        pinned
      end)

    on_exit(fn -> Enum.each(pinned, &ProgramStore.unpin/1) end)

    ninth = program(:crypto.strong_rand_bytes(32))
    assert :unavailable = ProgramStore.pin(ninth)

    leases =
      Enum.map(pinned, fn handle ->
        assert {:ok, lease} = ProgramStore.checkout(handle)
        lease
      end)

    Enum.each(leases, &ProgramStore.checkin/1)
  end

  test "owner death returns a lease and completes deferred unpinning" do
    program = program(:crypto.strong_rand_bytes(32))
    assert {:ok, pinned} = ProgramStore.pin(program)
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, lease} = ProgramStore.checkout(pinned)
        send(parent, {:leased, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:leased, lease}
    assert :ok = ProgramStore.unpin(pinned)
    assert {:ok, ^program} = ProgramStore.fetch(lease)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert eventually(fn -> ProgramStore.unpin(pinned) == :not_pinned end)
    assert {:error, :stale_lease} = ProgramStore.fetch(lease)
  end

  test "unpinned handles fail explicitly instead of copying or falling back" do
    assert {:ok, program} = QuickBEAM.VM.compile("1 + 1")
    assert {:ok, pinned} = QuickBEAM.VM.pin(program)
    assert :ok = QuickBEAM.VM.unpin(pinned)
    assert {:error, :pinned_program_unavailable} = QuickBEAM.VM.eval(pinned)
  end

  test "pin identity includes source and filename identity" do
    base = %Program{
      version: 26,
      fingerprint: "abi",
      atoms: {},
      root: %{filename: "first.js"},
      bytecode_digest: :crypto.strong_rand_bytes(32),
      bytecode_size: 100_000,
      source_digest: :crypto.strong_rand_bytes(32)
    }

    first = Program.put_pin_key(base)

    second =
      base |> put_in([Access.key(:root), :filename], "second.js") |> Program.put_pin_key()

    changed_source =
      %{base | source_digest: :crypto.strong_rand_bytes(32)} |> Program.put_pin_key()

    refute first.pin_key == second.pin_key
    refute first.pin_key == changed_source.pin_key
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp program(key) do
    %Program{
      version: QuickBEAM.VM.bytecode_version(),
      fingerprint: QuickBEAM.VM.fingerprint(),
      atoms: {},
      root: %{filename: "test.js"},
      bytecode_digest: key,
      bytecode_size: 100_000,
      pin_key: key
    }
  end
end
