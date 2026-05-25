defmodule QuickBEAM.VM.BuiltinDSLTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use QuickBEAM.VM.Builtin

    @ecma "20.1"
    builtin_definition("Sample", constructor: fn _args, this -> this end, length: 1)

    @ecma "20.1.2.19"
    static "keys", length: 1 do
      :ok
    end

    @ecma "20.1.3.6"
    proto "toString", length: 0 do
      "[object Sample]"
    end

    static "withoutEcma", length: 0 do
      :ok
    end

    def inline_methods do
      build_methods do
        @ecma "20.1.3.6"
        method "toString", length: 0 do
          "[object Sample]"
        end
      end
    end
  end

  test "@ecma annotates builtin definitions" do
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "20.1"} = Sample.builtin_definition()
  end

  test "@ecma annotates the next static builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.2.19"} =
             Sample.static_property_meta("keys")

    assert %QuickBEAM.VM.Builtin.Meta{ecma: nil} = Sample.static_property_meta("withoutEcma")
  end

  test "@ecma annotates the next prototype builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6"} =
             Sample.proto_property_meta("toString")
  end

  test "@ecma annotates inline method metadata" do
    method = Sample.inline_methods()["toString"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6", length: 0} =
             QuickBEAM.VM.Builtin.metadata_for(method)
  end

  test "runtime builtins can expose ECMA clause metadata" do
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "20.1"} =
             QuickBEAM.VM.Runtime.Object.builtin_definition()

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.2.19"} =
             QuickBEAM.VM.Runtime.Object.static_property_meta("keys")

    {:obj, ref} = QuickBEAM.VM.Runtime.Object.build_prototype()
    method = QuickBEAM.VM.Heap.get_obj(ref)["toString"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6"} =
             QuickBEAM.VM.Builtin.metadata_for(method)
  end
end
