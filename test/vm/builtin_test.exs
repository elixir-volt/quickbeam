defmodule QuickBEAM.VM.BuiltinTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use QuickBEAM.VM.Builtin

    static "assign", length: 2, constructable: false do
      :ok
    end

    proto "hasOwnProperty", length: 1 do
      true
    end

    builtin_definition("Sample",
      constructor: fn _, _ -> :sample end,
      length: 1,
      phase: :runtime,
      realm_intrinsic: :sample,
      prototype_properties: [
        %{key: "hasOwnProperty", value: proto_property("hasOwnProperty"), descriptor: %{}}
      ]
    )
  end

  test "static macros expose builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{
             name: "assign",
             length: 2,
             constructable?: false,
             enumerable?: false,
             configurable?: true,
             kind: :static
           } = Sample.static_property_meta("assign")

    assert QuickBEAM.VM.Builtin.static_meta(Sample, "assign").length == 2
    assert Sample.static_property_meta("missing") == nil
  end

  test "builtin definition macro exposes install metadata" do
    assert %QuickBEAM.VM.Builtin.Definition{
             name: "Sample",
             length: 1,
             phase: :runtime,
             realm_intrinsic: :sample,
             prototype_properties: [%{key: "hasOwnProperty"}]
           } = Sample.builtin_definition()
  end

  test "prototype macros expose builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{
             name: "hasOwnProperty",
             length: 1,
             constructable?: false,
             kind: :prototype
           } = Sample.proto_property_meta("hasOwnProperty")

    assert QuickBEAM.VM.Builtin.proto_meta(Sample, "hasOwnProperty").length == 1
    assert Sample.proto_property_meta("missing") == nil
  end
end
