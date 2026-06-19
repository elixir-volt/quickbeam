defmodule QuickBEAM.VM.ObjectPropertyIsEnumerableTest do
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

  var abrupt = {};
  abrupt[Symbol.toPrimitive] = function() { throw new Test262Error(); };
  var abruptName;
  try { Object.prototype.propertyIsEnumerable.call(null, abrupt); } catch (error) { abruptName = error.constructor.name; }

  [obj.propertyIsEnumerable(wrapper), count, abruptName];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} propertyIsEnumerable uses ToPropertyKey before ToObject" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, 1, "ReferenceError"]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
