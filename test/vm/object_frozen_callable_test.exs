defmodule QuickBEAM.VM.ObjectFrozenCallableTest do
  use ExUnit.Case, async: true

  @source ~S'''
  function f() {}
  Object.defineProperty(f, "property", { value: 12, writable: true, configurable: false });
  Object.preventExtensions(f);
  [Object.isFrozen(Object), Object.isFrozen(f), Object.isExtensible(Math), Object.isExtensible(1)];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object frozen/extensible checks handle callable and builtin objects" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [false, false, true, false]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
