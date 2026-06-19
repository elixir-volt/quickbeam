defmodule QuickBEAM.VM.ObjectModel.CopyProxyTest do
  use ExUnit.Case, async: true

  defp eval(source, mode) do
    {:ok, runtime} = QuickBEAM.start(apis: false)

    try do
      QuickBEAM.eval(runtime, source, mode: mode)
    after
      QuickBEAM.stop(runtime)
    end
  end

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} object spread copies only enumerable string keys from proxy ownKeys" do
      assert {:ok, %{"a" => 1}} =
               eval(
                 ~S'''
                 var sym = Symbol("s");
                 var target = { a: 1 };
                 Object.defineProperty(target, "hidden", { value: 2, enumerable: false });
                 target[sym] = 3;
                 var proxy = new Proxy(target, {
                   ownKeys: function(target) { return ["hidden", sym, "a"]; },
                   getOwnPropertyDescriptor: function(target, key) {
                     return Object.getOwnPropertyDescriptor(target, key);
                   },
                   get: function(target, key) { return target[key]; }
                 });
                 ({ ...proxy });
                 ''',
                 @mode
               )
    end
  end
end
