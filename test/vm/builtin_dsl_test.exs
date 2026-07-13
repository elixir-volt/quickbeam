defmodule QuickBEAM.VM.BuiltinDSLTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Builtin.{FunctionSpec, Registry}

  test "compiles declarative modules into immutable validated specs" do
    math = QuickBEAM.VM.Builtins.Math.builtin_spec()
    array = QuickBEAM.VM.Builtins.Array.builtin_spec()

    assert math.name == "Math"
    assert math.kind == :object
    assert math.profile == :core
    assert Enum.map(math.statics, & &1.key) == ~w(floor max min pow random round)
    assert Enum.all?(math.statics, &match?(%FunctionSpec{}, &1))

    assert array.name == "Array"
    assert array.kind == :extension
    assert [%FunctionSpec{key: "isArray", handler: :is_array, length: 1}] = array.statics

    assert Registry.modules(:core) == [
             QuickBEAM.VM.Builtins.Math,
             QuickBEAM.VM.Builtins.Array
           ]
  end

  test "installs real function objects with stable names, lengths, and descriptors" do
    source = """
    [
      typeof Math,
      Math.floor.name,
      Math.floor.length,
      Object.keys(Math).length,
      Array.isArray.name,
      Array.isArray.length,
      Array.isArray([]),
      Array.isArray({})
    ]
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok, ["object", "floor", 1, 0, "isArray", 1, true, false]} =
             QuickBEAM.VM.eval(program)
  end

  test "dispatches declarative handlers through the canonical invocation planner" do
    source = "[Math.floor(2.9),Math.round(2.4),Math.min(4,2),Math.max(4,2),Math.pow(2,3)]"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, [2, 2, 2, 4, 8.0]} = QuickBEAM.VM.eval(program)
  end
end
