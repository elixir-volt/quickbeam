defmodule QuickBEAM.VM.ClassDefaultDerivedTest do
  use ExUnit.Case, async: false

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "default derived constructors run public instance fields in #{@mode} mode" do
      {:ok, rt} = QuickBEAM.start(mode: @mode, apis: false)

      assert {:ok, 2} =
               QuickBEAM.eval(
                 rt,
                 "var A = class {}; var C = class extends A { y = 2; x = this.y }; new C().x;"
               )

      QuickBEAM.stop(rt)
    end

    test "default derived constructor field direct eval runs in initializer context in #{@mode} mode" do
      {:ok, rt} = QuickBEAM.start(mode: @mode, apis: false)

      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "var executed = false; var A = class {}; var C = class extends A { x = eval('executed = true; new.target;') }; new C(); executed;"
               )

      QuickBEAM.stop(rt)
    end
  end
end
