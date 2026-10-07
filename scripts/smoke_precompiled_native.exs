{:module, QuickBEAM.Native} = Code.ensure_loaded(QuickBEAM.Native)

resource = QuickBEAM.Native.start_runtime(self(), %{})
ref = QuickBEAM.Native.eval(resource, "40 + 2", 0, "")

receive do
  {^ref, {:ok, 42}} ->
    :ok

  {^ref, other} ->
    raise "unexpected eval response: #{inspect(other)}"
after
  30_000 -> raise "NIF eval timed out"
end

QuickBEAM.Native.stop_runtime(resource)
IO.puts("Precompiled NIF: load, startup, and eval passed")
