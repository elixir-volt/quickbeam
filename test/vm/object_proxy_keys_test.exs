defmodule QuickBEAM.VM.ObjectProxyKeysTest do
  use ExUnit.Case, async: true

  @source File.read!("test/test262/test/built-ins/Object/keys/proxy-keys.js")
          |> String.split("assert.sameValue(log.length, 10);")
          |> hd()
          |> Kernel.<>("[log.length, keys.length, keys[0]];")

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.keys observes proxy ownKeys array-like conversion" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [10, 1, "a"]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
