defmodule QuickBEAM.VM.ObjectKeysTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var threw = false;
  try { Object.keys(null); } catch (error) { threw = error.constructor === TypeError; }

  function foo() {}
  foo.x = 1;

  var arr = [];
  arr.a = 1;
  Object.defineProperty(arr, "length", { value: 2 });

  var fn = () => {};
  fn.a = 1;
  Object.defineProperty(fn, "length", { enumerable: true });

  [
    threw,
    Object.keys(foo).join(','),
    Object.getOwnPropertyNames(arr).join(','),
    Object.keys(fn).join(',')
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.keys handles nullish, callable objects, and sparse arrays" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, [true, "x", "length,a", "length,a"]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
