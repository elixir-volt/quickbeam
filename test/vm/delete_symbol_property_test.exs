defmodule QuickBEAM.VM.DeleteSymbolPropertyTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var sym = Symbol.toStringTag;
  var obj = {};
  obj[sym] = "tag";
  delete obj[sym];

  var arr = [];
  arr[sym] = "tag";
  delete arr[sym];

  [obj.hasOwnProperty(sym), arr.hasOwnProperty(sym)];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} delete handles symbol property keys" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [false, false]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
