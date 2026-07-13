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

    assert Enum.map(array.prototype, & &1.key) ==
             ~w(concat filter forEach join map push reduce slice some)

    assert Registry.modules(:core) == [
             QuickBEAM.VM.Builtins.Math,
             QuickBEAM.VM.Builtins.Array,
             QuickBEAM.VM.Builtins.String,
             QuickBEAM.VM.Builtins.Object
           ]

    assert QuickBEAM.VM.Builtins.String.builtin_spec().kind == :extension

    assert Enum.map(QuickBEAM.VM.Builtins.Object.builtin_spec().statics, & &1.key) ==
             ~w(assign create defineProperty getOwnPropertyDescriptor getOwnPropertyNames getPrototypeOf keys setPrototypeOf)
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
      Array.isArray({}),
      String.fromCharCode.name,
      String.fromCharCode.length,
      Object.assign.name,
      Object.assign.length,
      Array.prototype.map.name,
      Array.prototype.map.length
    ]
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok,
            [
              "object",
              "floor",
              1,
              0,
              "isArray",
              1,
              true,
              false,
              "fromCharCode",
              1,
              "assign",
              2,
              "map",
              1
            ]} = QuickBEAM.VM.eval(program)
  end

  test "runs immediate and resumable declarative handlers through canonical invocation" do
    source = """
    (()=>{
      let seen=0
      let target={set value(next){seen=next}}
      let source={get value(){return 42}}
      let assigned=Object.assign(target,source)
      return [seen,assigned===target,String.fromCharCode(65,66)]
    })()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, [42, true, "AB"]} = QuickBEAM.VM.eval(program)
  end

  test "dispatches declarative handlers through the canonical invocation planner" do
    source = "[Math.floor(2.9),Math.round(2.4),Math.min(4,2),Math.max(4,2),Math.pow(2,3)]"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, [2, 2, 2, 4, 8.0]} = QuickBEAM.VM.eval(program)
  end
end
