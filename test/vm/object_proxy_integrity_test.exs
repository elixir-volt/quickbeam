defmodule QuickBEAM.VM.ObjectProxyIntegrityTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var target = {};
  var sym = Symbol();
  target[sym] = 1;
  target.foo = 2;
  target[0] = 3;
  Object.freeze(target);

  var keys = [];
  var proxy = new Proxy(target, {
    getOwnPropertyDescriptor: function(target, key) {
      keys.push(key);
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });

  Object.isFrozen(proxy) && keys[0] === "0" && keys[1] === "foo" && keys[2] === sym;
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object integrity checks query proxy descriptors in own-key order" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, true} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
