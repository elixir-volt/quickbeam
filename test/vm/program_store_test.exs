defmodule QuickBEAM.VM.ProgramStoreTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.ProgramStore

  test "shares one immutable program under concurrent bounded leases" do
    program = program(:crypto.strong_rand_bytes(32))

    assert {:ok, shared} = ProgramStore.share(program)
    parent = self()

    tasks =
      Enum.map(1..20, fn _index ->
        Task.async(fn ->
          {:ok, lease} = ProgramStore.checkout(shared)
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
    assert :ok = ProgramStore.release(shared)
    assert Enum.all?(leases, fn lease -> ProgramStore.fetch(lease) == {:ok, program} end)

    Enum.each(tasks, &send(&1.pid, :finish))
    Enum.each(tasks, &Task.await/1)
    assert eventually(fn -> ProgramStore.release(shared) == :not_shared end)
    assert Enum.all?(leases, fn lease -> ProgramStore.fetch(lease) == {:error, :stale_lease} end)
  end

  test "restores fixed persistent slots after the store restarts" do
    program = program(:crypto.strong_rand_bytes(32))
    assert {:ok, shared} = ProgramStore.share(program)

    old_store = Process.whereis(ProgramStore)
    monitor = Process.monitor(old_store)
    Process.exit(old_store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_store, :killed}
    assert eventually(fn -> is_pid(Process.whereis(ProgramStore)) end)

    assert {:ok, lease} = ProgramStore.checkout(shared)
    assert {:ok, ^program} = ProgramStore.fetch(lease)
    ProgramStore.checkin(lease)
    assert :ok = ProgramStore.release(shared)
  end

  test "rejects programs above the bounded shared bytecode size" do
    program = %{program(:crypto.strong_rand_bytes(32)) | bytecode_size: 2 * 1024 * 1024 + 1}
    assert {:error, :program_too_large} = ProgramStore.share(program)
    assert :not_shared = ProgramStore.release(program)
  end

  test "released handles fail explicitly instead of copying or falling back" do
    assert {:ok, program} = QuickBEAM.VM.compile("1 + 1")
    assert {:ok, shared} = QuickBEAM.VM.share_program(program)
    assert :ok = QuickBEAM.VM.release_program(shared)
    assert {:error, :shared_program_unavailable} = QuickBEAM.VM.eval(shared)
  end

  test "share identity includes source and filename identity" do
    base = %Program{
      version: 26,
      fingerprint: "abi",
      atoms: {},
      root: %{filename: "first.js"},
      bytecode_digest: :crypto.strong_rand_bytes(32),
      bytecode_size: 100_000,
      source_digest: :crypto.strong_rand_bytes(32)
    }

    first = Program.put_share_key(base)

    second =
      base |> put_in([Access.key(:root), :filename], "second.js") |> Program.put_share_key()

    changed_source =
      %{base | source_digest: :crypto.strong_rand_bytes(32)} |> Program.put_share_key()

    refute first.share_key == second.share_key
    refute first.share_key == changed_source.share_key
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
      share_key: key
    }
  end
end
