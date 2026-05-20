defmodule QuickBEAM.VM.ObjectProtoAccessorTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var descriptor = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__");
  var proto = {};
  var obj = {};
  descriptor.set.call(obj, proto);

  var nullishThrew = false;
  try { descriptor.set.call(null); } catch (error) { nullishThrew = error.constructor === TypeError; }

  var nonExtProto = {};
  var nonExt = Object.create(nonExtProto);
  Object.preventExtensions(nonExt);
  nonExt.__proto__ = nonExtProto;
  var nonExtensibleThrew = false;
  try { nonExt.__proto__ = {}; } catch (error) { nonExtensibleThrew = error.constructor === TypeError; }

  var root = {};
  var leaf = Object.create(root);
  var cycleThrew = false;
  try { descriptor.set.call(root, leaf); } catch (error) { cycleThrew = error.constructor === TypeError; }

  Object.prototype.__proto__ = null;
  var immutableThrew = false;
  try { Object.prototype.__proto__ = {}; } catch (error) { immutableThrew = error.constructor === TypeError; }

  [
    descriptor.get.name,
    descriptor.get.length,
    descriptor.enumerable,
    descriptor.configurable,
    descriptor.get.call(obj) === proto,
    cycleThrew,
    immutableThrew,
    nullishThrew,
    nonExtensibleThrew,
    Object.getPrototypeOf(nonExt) === nonExtProto
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.prototype.__proto__ is an accessor with named getter" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, ["get __proto__", 0, false, true, true, true, true, true, true, true]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
