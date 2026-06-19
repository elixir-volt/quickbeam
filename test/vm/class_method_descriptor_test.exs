defmodule QuickBEAM.VM.ClassMethodDescriptorTest do
  use ExUnit.Case, async: false

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "class heritage rejects constructors with invalid prototype in #{@mode} mode" do
      {:ok, rt} = QuickBEAM.start(mode: @mode, apis: false)

      assert {:ok, "TypeError"} =
               QuickBEAM.eval(
                 rt,
                 "var Base = function(){}.bind(); try { class C extends Base {}; 'no' } catch (e) { e.name }"
               )

      QuickBEAM.stop(rt)
    end

    test "class methods and accessors are not constructors in #{@mode} mode" do
      {:ok, rt} = QuickBEAM.start(mode: @mode, apis: false)

      assert {:ok, [false, false, false, false, false]} =
               QuickBEAM.eval(
                 rt,
                 ~S|class C { method(){} static sm(){} get x(){ return 1 } static get sx(){ return 2 } static set sy(v){} } [
                   'prototype' in Object.getOwnPropertyDescriptor(C.prototype, 'method').value,
                   'prototype' in Object.getOwnPropertyDescriptor(C, 'sm').value,
                   'prototype' in Object.getOwnPropertyDescriptor(C.prototype, 'x').get,
                   Object.getOwnPropertyDescriptor(C, 'sx').enumerable,
                   Object.getOwnPropertyDescriptor(C, 'sy').enumerable
                 ]|
               )

      QuickBEAM.stop(rt)
    end
  end
end
