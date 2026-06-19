defmodule QuickBEAM.VM.ObjectDescriptorsOrderTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var symA = Symbol("a");
  var symB = Symbol("b");
  var obj = {};
  obj[symA] = 1;
  obj[symB] = 2;

  var re = /(?:)/g;
  re.a = 1;
  Object.defineProperty(re, "lastIndex", { value: 2 });

  [
    Reflect.ownKeys(Object.getOwnPropertyDescriptors(obj))[0] === symA,
    Reflect.ownKeys(Object.getOwnPropertyDescriptors(re)).join(',')
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.getOwnPropertyDescriptors preserves source own-key order" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, "lastIndex,a"]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
