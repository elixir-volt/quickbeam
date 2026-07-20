defmodule QuickBEAM.VM.Builtin.DSLTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Array, as: ArrayBuiltin
  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtin.Contract.Error, as: ContractError
  alias QuickBEAM.VM.Builtin.Error.Type, as: TypeErrorBuiltin
  alias QuickBEAM.VM.Builtin.Function, as: FunctionBuiltin
  alias QuickBEAM.VM.Builtin.Installer
  alias QuickBEAM.VM.Builtin.Math, as: MathBuiltin
  alias QuickBEAM.VM.Builtin.Object, as: ObjectBuiltin
  alias QuickBEAM.VM.Builtin.Promise, as: PromiseBuiltin
  alias QuickBEAM.VM.Builtin.Registry
  alias QuickBEAM.VM.Builtin.Set, as: SetBuiltin
  alias QuickBEAM.VM.Builtin.Spec
  alias QuickBEAM.VM.Builtin.Spec.Accessor, as: AccessorSpec
  alias QuickBEAM.VM.Builtin.Spec.Alias, as: AliasSpec
  alias QuickBEAM.VM.Builtin.Spec.Function, as: FunctionSpec
  alias QuickBEAM.VM.Builtin.Spec.Property, as: PropertySpec
  alias QuickBEAM.VM.Builtin.String, as: StringBuiltin
  alias QuickBEAM.VM.Builtin.Symbol, as: SymbolBuiltin
  alias QuickBEAM.VM.Builtin.Validator
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Symbol, as: RuntimeSymbol

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

    assert {:ok, 42} = Property.get(fixture, "answer", execution)
    assert {:ok, %Reference{} = echo} = Property.get(fixture, "echo", execution)
    assert {:ok, "echo"} = Property.get(echo, "name", execution)

    assert {:ok, {:accessor, %Reference{} = getter, ^fixture}} =
             Property.get(fixture, "version", execution)

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
    math = MathBuiltin.builtin_spec()
    array = ArrayBuiltin.builtin_spec()

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
    assert [%FunctionSpec{key: "isArray", handler: :array?, length: 1}] = array.statics

    assert Enum.map(array.prototype, & &1.key) ==
             ~w(concat filter forEach includes join map push reduce slice some sort)

    assert Registry.modules(:core) == [
             QuickBEAM.VM.Builtin.Object,
             QuickBEAM.VM.Builtin.Function,
             QuickBEAM.VM.Builtin.Array,
             QuickBEAM.VM.Builtin.Boolean,
             QuickBEAM.VM.Builtin.Error,
             QuickBEAM.VM.Builtin.Math,
             QuickBEAM.VM.Builtin.Number,
             QuickBEAM.VM.Builtin.String,
             QuickBEAM.VM.Builtin.Symbol,
             QuickBEAM.VM.Builtin.Uint8Array,
             QuickBEAM.VM.Builtin.WeakMap,
             QuickBEAM.VM.Builtin.Error.Eval,
             QuickBEAM.VM.Builtin.Map,
             QuickBEAM.VM.Builtin.Promise,
             QuickBEAM.VM.Builtin.Error.Range,
             QuickBEAM.VM.Builtin.Error.Reference,
             QuickBEAM.VM.Builtin.Set,
             QuickBEAM.VM.Builtin.Error.Syntax,
             QuickBEAM.VM.Builtin.Error.Type,
             QuickBEAM.VM.Builtin.Error.URI,
             QuickBEAM.VM.Builtin.WeakSet
           ]

    refute QuickBEAM.VM.Builtin.Console in Registry.modules(:core)
    assert QuickBEAM.VM.Builtin.Console in Registry.modules(:ssr)
    generation = Registry.generation()
    assert Registry.modules(:core) == Enum.map(Registry.refresh()[:core], & &1.module)
    assert Registry.generation() == generation + 1

    assert StringBuiltin.builtin_spec().kind == :constructor

    object = ObjectBuiltin.builtin_spec()
    assert object.prototype_spec.extends == nil
    assert object.prototype_spec.default_for == :ordinary

    function = FunctionBuiltin.builtin_spec()
    assert function.prototype_spec.extends == "Object"
    assert function.prototype_spec.kind == :function
    assert function.prototype_spec.callable == :prototype_call
    assert function.prototype_spec.default_for == :function

    promise = PromiseBuiltin.builtin_spec()
    assert promise.kind == :constructor
    assert promise.constructor == :construct
    assert promise.depends_on == ["Object", "Function", "Symbol"]

    error = TypeErrorBuiltin.builtin_spec()
    assert error.prototype_spec.extends == "Error"
    assert error.prototype_spec.error_type == "TypeError"

    set = SetBuiltin.builtin_spec()
    assert set.kind == :constructor
    assert Enum.any?(set.prototype, &match?(%AliasSpec{}, &1))

    symbol = SymbolBuiltin.builtin_spec()
    assert symbol.kind == :function
    assert symbol.constructor == nil

    assert Enum.any?(
             symbol.statics,
             &match?(%{key: "iterator", value: %RuntimeSymbol{id: :iterator}}, &1)
           )

    assert Enum.map(ObjectBuiltin.builtin_spec().statics, & &1.key) ==
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
    %State{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end
end
