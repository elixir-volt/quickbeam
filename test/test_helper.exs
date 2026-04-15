Application.ensure_all_started(:telemetry)

# Compile the test N-API addon from C source
test_addon_src = Path.expand("support/test_addon.c", __DIR__)
test_addon_out = Path.expand("support/test_addon.node", __DIR__)
test_addon_hdr = Path.expand("support", __DIR__)

unless File.exists?(test_addon_out) and
         File.stat!(test_addon_out).mtime >= File.stat!(test_addon_src).mtime do
  extra =
    case :os.type() do
      {:unix, :darwin} -> ["-undefined", "dynamic_lookup"]
      _ -> ["-fPIC"]
    end

  args =
    ["-shared", "-fvisibility=hidden"] ++
      extra ++
      ["-o", test_addon_out, "-I", test_addon_hdr, test_addon_src]

  {_, 0} = System.cmd("cc", args, stderr_to_stdout: true)
end

ExUnit.start(exclude: [:pending_beam])

# Force garbage collection before BEAM exits to prevent NIF finalizer crashes.
# On OTP 27.0.x, the BEAM shutdown races with QuickJS worker thread cleanup.
System.at_exit(fn _ ->
  :erlang.garbage_collect()
  Process.sleep(200)
end)
