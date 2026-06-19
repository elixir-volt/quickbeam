defmodule QuickBEAM.VM.ObjectLookupAccessorTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var getter = function() { return 1; };
  var setter = function(v) {};
  var root = Object.defineProperty({}, 'x', { get: getter });
  var subject = Object.create(root);
  Object.defineProperty(subject, 'y', { set: setter });

  var count = 0;
  try { subject.__defineGetter__({ toString: function() { count++; } }, 1); } catch (error) {}

  [
    subject.__lookupGetter__('x') === getter,
    subject.__lookupGetter__('y'),
    subject.__lookupSetter__('y') === setter,
    subject.__lookupGetter__('missing'),
    count,
    Object.prototype.__lookupGetter__.length
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object prototype lookup accessors walk prototype descriptors" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, [true, nil, true, nil, 0, 1]} = QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
