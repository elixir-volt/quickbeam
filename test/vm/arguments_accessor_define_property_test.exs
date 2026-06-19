defmodule QuickBEAM.VM.ArgumentsAccessorDefinePropertyTest do
  use ExUnit.Case, async: true

  @property_helper QuickBEAM.Test262.harness_source(["propertyHelper.js"])

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} arguments accessor defineProperty detaches mapped parameter" do
      source =
        @property_helper <>
          ~S'''
          (function(a, b, c) {
            function getFunc1() { return 10; }
            Object.defineProperty(arguments, "0", { get: getFunc1, enumerable: true, configurable: true });
            function getFunc2() { return 20; }
            Object.defineProperty(arguments, "0", { get: getFunc2, enumerable: false, configurable: false });

            assert.sameValue(a, 0);
            verifyEqualTo(arguments, "0", 20);
            verifyProperty(arguments, "0", { enumerable: false, configurable: false });
          }(0, 1, 2));
          '''

      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, nil} = QuickBEAM.eval(runtime, source, mode: @mode)
      QuickBEAM.stop(runtime)
    end

    test "#{mode} arguments data defineProperty updates mapped parameter" do
      source =
        ~S'''
        var obj = (function(x) { return arguments; }(1001));
        Object.defineProperty(obj, "0", { value: 2010, writable: true, enumerable: true, configurable: false });
        [obj[0], Object.getOwnPropertyDescriptor(obj, "0").configurable];
        '''

      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [2010, false]} = QuickBEAM.eval(runtime, source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
