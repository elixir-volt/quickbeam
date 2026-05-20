defmodule QuickBEAM.VM.ObjectProtoAccessorTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var descriptor = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__");
  var proto = {};
  var obj = {};
  descriptor.set.call(obj, proto);

  var root = {};
  var leaf = Object.create(root);
  var cycleThrew = false;
  try { descriptor.set.call(root, leaf); } catch (error) { cycleThrew = error.constructor === TypeError; }

  [
    descriptor.get.name,
    descriptor.get.length,
    descriptor.enumerable,
    descriptor.configurable,
    descriptor.get.call(obj) === proto,
    cycleThrew
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.prototype.__proto__ is an accessor with named getter" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, ["get __proto__", 0, false, true, true, true]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
