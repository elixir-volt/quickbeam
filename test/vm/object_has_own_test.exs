defmodule QuickBEAM.VM.ObjectHasOwnTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var obj = {};
  var sym = Symbol();
  var count = 0;
  var wrapper = {};
  wrapper[Symbol.toPrimitive] = function() {
    count += 1;
    return sym;
  };
  obj[sym] = 1;
  var protoHasOwnCount = 0;
  var protoWrapper = {};
  protoWrapper[Symbol.toPrimitive] = function() {
    protoHasOwnCount += 1;
    return sym;
  };

  [Object.hasOwn(obj, wrapper), count, obj.hasOwnProperty(protoWrapper), protoHasOwnCount];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.hasOwn uses ToPropertyKey for symbol-producing objects" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, 1, true, 1]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
