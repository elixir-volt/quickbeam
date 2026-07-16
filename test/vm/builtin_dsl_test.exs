defmodule QuickBEAM.VM.BuiltinDSLTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Builtin.{
    AccessorSpec,
    Call,
    ContractError,
    FunctionSpec,
    Installer,
    PropertySpec,
    Registry,
    Spec,
    Validator
  }

  alias QuickBEAM.VM.{Builtin, Execution, Invocation, Properties, Reference}

  defmodule Fixture do
    use QuickBEAM.VM.Builtin

    builtin "Fixture", kind: :namespace, profiles: [:core, :test] do
      constant "answer", 40 + 2
      static :echo, length: 1
      static :invalid_result, js: "invalid", length: 0
      static_accessor :version, get: :version
    end

    def echo(%Call{arguments: arguments, execution: execution}),
      do: {:ok, List.first(arguments, :undefined), execution}

    def invalid_result(_call), do: :invalid
    def version(%Call{execution: execution}), do: {:ok, "1.0", execution}
  end

  test "evaluates constants and emits typed function and accessor specs" do
    spec = Fixture.builtin_spec()

    assert spec.profiles == [:core, :test]
    assert [%PropertySpec{key: "answer", value: 42} | _] = spec.statics
    assert Enum.any?(spec.statics, &match?(%FunctionSpec{key: "echo"}, &1))
    assert Enum.any?(spec.statics, &match?(%AccessorSpec{key: "version", getter: :version}, &1))
  end

  test "validator rejects duplicate keys before installation" do
    duplicate = %FunctionSpec{key: "same", handler: :echo}

    spec = %Spec{
      name: "Duplicate",
      module: Fixture,
      kind: :namespace,
      statics: [duplicate, duplicate]
    }

    assert_raise CompileError, ~r/duplicate static keys/, fn ->
      Validator.validate!(spec, __ENV__)
    end
  end

  test "installs constants, methods, and accessors through one descriptor path" do
    execution = Installer.install_all(execution(), [Fixture], :test)
    fixture = Map.fetch!(execution.globals, "Fixture")

    assert {:ok, 42} = Properties.get(fixture, "answer", execution)
    assert {:ok, %Reference{} = echo} = Properties.get(fixture, "echo", execution)
    assert {:ok, "echo"} = Properties.get(echo, "name", execution)

    assert {:ok, {:accessor, %Reference{} = getter, ^fixture}} =
             Properties.get(fixture, "version", execution)

    assert Invocation.callable?(getter, execution)
  end

  test "rejects malformed builtin handler results as infrastructure contract errors" do
    execution = execution()
    token = {:declared_builtin, Fixture, :invalid_result}

    call = %Call{
      arguments: [],
      this: :undefined,
      caller: nil,
      tail?: false,
      execution: execution
    }

    assert_raise ContractError, fn -> Builtin.invoke(token, call) end
  end

  test "compiles declarative modules into immutable validated specs" do
    math = QuickBEAM.VM.Builtins.Math.builtin_spec()
    array = QuickBEAM.VM.Builtins.Array.builtin_spec()

    assert math.name == "Math"
    assert math.kind == :namespace
    assert math.profiles == [:core]
    assert Enum.map(math.statics, & &1.key) == ~w(E PI floor max min pow random round)
    assert Enum.count(math.statics, &match?(%FunctionSpec{}, &1)) == 6

    assert Enum.any?(
             math.statics,
             &match?(%PropertySpec{key: "PI", value: value} when value > 3.14, &1)
           )

    assert array.name == "Array"
    assert array.kind == :constructor
    assert array.prototype_spec.kind == :array
    assert array.prototype_spec.default_for == :array
    assert [%FunctionSpec{key: "isArray", handler: :is_array, length: 1}] = array.statics

    assert Enum.map(array.prototype, & &1.key) ==
             ~w(concat filter forEach includes join map push reduce slice some sort)

    assert Registry.modules(:core) == [
             QuickBEAM.VM.Builtins.Object,
             QuickBEAM.VM.Builtins.Function,
             QuickBEAM.VM.Builtins.Array,
             QuickBEAM.VM.Builtins.Boolean,
             QuickBEAM.VM.Builtins.Error,
             QuickBEAM.VM.Builtins.Math,
             QuickBEAM.VM.Builtins.Number,
             QuickBEAM.VM.Builtins.String,
             QuickBEAM.VM.Builtins.Symbol,
             QuickBEAM.VM.Builtins.Uint8Array,
             QuickBEAM.VM.Builtins.WeakMap,
             QuickBEAM.VM.Builtins.EvalError,
             QuickBEAM.VM.Builtins.Map,
             QuickBEAM.VM.Builtins.Promise,
             QuickBEAM.VM.Builtins.RangeError,
             QuickBEAM.VM.Builtins.ReferenceError,
             QuickBEAM.VM.Builtins.Set,
             QuickBEAM.VM.Builtins.SyntaxError,
             QuickBEAM.VM.Builtins.TypeError,
             QuickBEAM.VM.Builtins.URIError,
             QuickBEAM.VM.Builtins.WeakSet
           ]

    refute QuickBEAM.VM.Builtins.Console in Registry.modules(:core)
    assert QuickBEAM.VM.Builtins.Console in Registry.modules(:ssr)
    generation = Registry.generation()
    assert Registry.modules(:core) == Enum.map(Registry.refresh()[:core], & &1.module)
    assert Registry.generation() == generation + 1

    assert QuickBEAM.VM.Builtins.String.builtin_spec().kind == :constructor

    object = QuickBEAM.VM.Builtins.Object.builtin_spec()
    assert object.prototype_spec.extends == nil
    assert object.prototype_spec.default_for == :ordinary

    function = QuickBEAM.VM.Builtins.Function.builtin_spec()
    assert function.prototype_spec.extends == "Object"
    assert function.prototype_spec.kind == :function
    assert function.prototype_spec.callable == :prototype_call
    assert function.prototype_spec.default_for == :function

    promise = QuickBEAM.VM.Builtins.Promise.builtin_spec()
    assert promise.kind == :constructor
    assert promise.constructor == :construct
    assert promise.depends_on == ["Object", "Function", "Symbol"]

    error = QuickBEAM.VM.Builtins.TypeError.builtin_spec()
    assert error.prototype_spec.extends == "Error"
    assert error.prototype_spec.error_type == "TypeError"

    set = QuickBEAM.VM.Builtins.Set.builtin_spec()
    assert set.kind == :constructor
    assert Enum.any?(set.prototype, &match?(%QuickBEAM.VM.Builtin.AliasSpec{}, &1))

    symbol = QuickBEAM.VM.Builtins.Symbol.builtin_spec()
    assert symbol.kind == :function
    assert symbol.constructor == nil

    assert Enum.any?(
             symbol.statics,
             &match?(%{key: "iterator", value: %QuickBEAM.VM.Symbol{id: :iterator}}, &1)
           )

    assert Enum.map(QuickBEAM.VM.Builtins.Object.builtin_spec().statics, & &1.key) ==
             ~w(assign create defineProperty defineProperties freeze getOwnPropertyDescriptor getOwnPropertyNames getPrototypeOf keys setPrototypeOf)
  end

  test "installs callable but non-constructable Symbol semantics" do
    source =
      "(()=>{let first=Symbol();let second=Symbol();let rejected=false;try{new Symbol()}catch(error){rejected=error instanceof TypeError}return [typeof first,first===second,rejected]})()"

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, ["symbol", false, true]} = QuickBEAM.VM.eval(program)
  end

  test "installs real function objects with stable names, lengths, and descriptors" do
    source = """
    [
      typeof Math,
      Math.floor.name,
      Math.floor.length,
      Object.keys(Math).length,
      Math.PI > 3.14,
      Math.E > 2.71,
      Array.isArray.name,
      Array.isArray.length,
      Array.isArray([]),
      Array.isArray({}),
      String.fromCharCode.name,
      String.fromCharCode.length,
      Object.assign.name,
      Object.assign.length,
      Array.prototype.map.name,
      Array.prototype.map.length,
      String.prototype.slice.name,
      String.prototype.slice.length,
      Number.prototype.toString.name,
      Number.prototype.toString.length
    ]
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok,
            [
              "object",
              "floor",
              1,
              0,
              true,
              true,
              "isArray",
              1,
              true,
              false,
              "fromCharCode",
              1,
              "assign",
              2,
              "map",
              1,
              "slice",
              2,
              "toString",
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

  test "dispatches declarative String and Number prototype methods" do
    source = """
    [
      "Alpha".toLowerCase(),
      "alpha".startsWith("al"),
      "alpha".includes("ph"),
      "a,b".split(",").join("-"),
      (255).toString(16),
      new Number(12).toFixed(2),
      new String("value").toString()
    ]
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok, ["alpha", true, true, "a-b", "ff", "12.00", "value"]} =
             QuickBEAM.VM.eval(program)
  end

  test "dispatches declarative handlers through the canonical invocation planner" do
    source = "[Math.floor(2.9),Math.round(2.4),Math.min(4,2),Math.max(4,2),Math.pow(2,3)]"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, [2, 2, 2, 4, 8.0]} = QuickBEAM.VM.eval(program)
  end

  defp execution do
    %Execution{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end
end
