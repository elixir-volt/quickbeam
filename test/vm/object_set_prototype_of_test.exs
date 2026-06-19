defmodule QuickBEAM.VM.ObjectSetPrototypeOfTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var objectProtoThrew = false;
  try { Object.setPrototypeOf(Object.prototype, {}); } catch (error) { objectProtoThrew = error.constructor === TypeError; }

  var root = {};
  var leaf = Object.create(root);
  var cycleThrew = false;
  try { Object.setPrototypeOf(root, leaf); } catch (error) { cycleThrew = error.constructor === TypeError; }

  [
    objectProtoThrew,
    Reflect.setPrototypeOf(Object.prototype, {}) === false,
    cycleThrew,
    Object.getPrototypeOf(root) === Object.prototype
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.setPrototypeOf rejects immutable prototypes and cycles" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, true, true, true]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
