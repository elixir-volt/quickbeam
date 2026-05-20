defmodule QuickBEAM.VM.ArgumentsDefinePropertyTest do
  use ExUnit.Case, async: true

  @property_helper QuickBEAM.Test262.harness_source(["propertyHelper.js"])

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} defineProperties recreates deleted mapped arguments index as ordinary data" do
      source =
        @property_helper <>
          ~S'''
          var arg;
          (function fun(a, b, c) { arg = arguments; }(0, 1, 2));
          delete arg[0];
          Object.defineProperties(arg, {"0": {value: 10, writable: true, enumerable: true, configurable: true}});
          verifyProperty(arg, "0", {value: 10, writable: true, enumerable: true, configurable: true});
          '''

      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, true} = QuickBEAM.eval(runtime, source, mode: @mode)
      QuickBEAM.stop(runtime)
    end

    test "#{mode} defineProperties updates mapped arguments value before deleting non-writable map" do
      source =
        @property_helper <>
          ~S'''
          var arg;
          (function fun(a, b, c) { arg = arguments; }(0, 1, 2));
          Object.defineProperties(arg, {"0": {value: 20, writable: false, enumerable: false, configurable: false}});
          verifyProperty(arg, "0", {value: 20, writable: false, enumerable: false, configurable: false});
          '''

      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, true} = QuickBEAM.eval(runtime, source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
