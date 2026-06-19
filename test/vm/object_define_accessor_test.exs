defmodule QuickBEAM.VM.ObjectDefineAccessorTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var obj = {};
  var getter = function() { return 42; };
  obj.__defineGetter__('x', getter);
  var desc = Object.getOwnPropertyDescriptor(obj, 'x');
  [obj.x, desc.get === getter, desc.enumerable, desc.configurable, Object.prototype.hasOwnProperty('__defineGetter__')];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.prototype.__defineGetter__ defines enumerable configurable accessors" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [42, true, true, true, true]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
