defmodule QuickBEAM.VM.ReflectDefineCallableTest do
  use ExUnit.Case, async: true

  @source ~S'''
  function f() {}
  var defineFunction = Reflect.defineProperty(f, 'arguments', { writable: false, configurable: false });
  var functionDesc = Reflect.getOwnPropertyDescriptor(f, 'arguments');

  var defineRegExp = Reflect.defineProperty(RegExp, '$1', { value: 'x', writable: false, configurable: false });
  var regexpDesc = Reflect.getOwnPropertyDescriptor(RegExp, '$1');

  [defineFunction, functionDesc.configurable, functionDesc.writable, defineRegExp, regexpDesc.value, regexpDesc.configurable];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Reflect.defineProperty accepts callable and RegExp objects" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, [true, false, false, true, "x", false]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
