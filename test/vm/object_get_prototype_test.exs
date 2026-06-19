defmodule QuickBEAM.VM.ObjectGetPrototypeTest do
  use ExUnit.Case, async: true

  @source ~S'''
  function args() { return arguments; }
  [
    Object.getPrototypeOf(Math) === Object.prototype,
    Object.getPrototypeOf(JSON) === Object.prototype,
    Object.getPrototypeOf(args(1)) === Object.prototype,
    Object.getPrototypeOf(Object.prototype),
    Object.getPrototypeOf(Object.create(null))
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.getPrototypeOf returns Object.prototype for ordinary namespace and arguments objects" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, true, true, nil, nil]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
