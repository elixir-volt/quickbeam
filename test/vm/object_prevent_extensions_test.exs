defmodule QuickBEAM.VM.ObjectPreventExtensionsTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var argObj;
  (function() { argObj = arguments; }());
  Object.preventExtensions(argObj);
  argObj[0] = "new";

  function fn() {}
  Object.preventExtensions(fn);
  fn.extra = 1;

  var arr = [];
  Object.preventExtensions(arr);
  arr.extra = 1;
  arr[0] = 1;

  [
    Object.isExtensible(argObj),
    argObj.hasOwnProperty("0"),
    Object.isExtensible(fn),
    fn.hasOwnProperty("extra"),
    arr.hasOwnProperty("extra"),
    arr.hasOwnProperty("0")
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} preventExtensions rejects new properties on arguments, arrays, and functions" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, [false, false, false, false, false, false]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
