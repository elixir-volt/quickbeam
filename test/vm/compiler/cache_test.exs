defmodule QuickBEAM.VM.Compiler.CacheTest do
  use ExUnit.Case, async: false

  test "compiler cache directory and clear API use configured cache root" do
    previous_cache = System.get_env("QUICKBEAM_COMPILER_CACHE")
    previous_dir = System.get_env("QUICKBEAM_COMPILER_CACHE_DIR")

    dir =
      Path.join(
        System.tmp_dir!(),
        "quickbeam-compiler-cache-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env("QUICKBEAM_COMPILER_CACHE", previous_cache)
      restore_env("QUICKBEAM_COMPILER_CACHE_DIR", previous_dir)
      File.rm_rf(dir)
    end)

    System.put_env("QUICKBEAM_COMPILER_CACHE", "1")
    System.put_env("QUICKBEAM_COMPILER_CACHE_DIR", dir)

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stale.beam"), "stale")

    assert QuickBEAM.compiler_cache_dir() == dir
    assert QuickBEAM.clear_compiler_cache() == :ok
    refute File.exists?(dir)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
