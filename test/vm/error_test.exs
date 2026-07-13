defmodule QuickBEAM.VM.ErrorTest do
  use ExUnit.Case, async: true

  test "returns source-mapped JavaScript errors with JavaScript call frames" do
    source = """
    function inner() {
      return missingValue + 1
    }
    function outer() {
      return 1 + inner()
    }
    outer()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: "renderer.js")

    assert {:error, %QuickBEAM.JSError{} = error} = QuickBEAM.VM.eval(program)
    assert error.name == "ReferenceError"
    assert error.message == "missingValue is not defined"
    assert error.filename == "renderer.js"
    assert error.line == 1
    assert Enum.map(error.frames, & &1.function) == ["inner", "outer", "<eval>"]
    assert error.stack =~ "ReferenceError: missingValue is not defined"
    assert error.stack =~ "at inner (renderer.js:1:"
    assert error.stack =~ "at outer (renderer.js:5:"
    refute error.stack =~ "lib/quickbeam"
  end

  test "exposes generated errors as JavaScript error-like values to catch blocks" do
    source = "try { missingValue } catch (error) { error.name + ': ' + error.message }"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, "ReferenceError: missingValue is not defined"} = QuickBEAM.VM.eval(program)
  end

  test "gives generated errors JavaScript constructor identity" do
    source = """
    try {
      missingValue
    } catch (error) {
      [
        error instanceof ReferenceError,
        error instanceof Error,
        error.name,
        error.message,
        error.toString()
      ]
    }
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok,
            [
              true,
              true,
              "ReferenceError",
              "missingValue is not defined",
              "ReferenceError: missingValue is not defined"
            ]} = QuickBEAM.VM.eval(program)
  end

  test "supports constructed derived errors and stable uncaught conversion" do
    source = """
    const error = new RangeError("outside range")
    if (!(error instanceof RangeError) || !(error instanceof Error)) throw 1
    throw error
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: "range.js")
    assert {:error, %QuickBEAM.JSError{} = error} = QuickBEAM.VM.eval(program)
    assert error.name == "RangeError"
    assert error.message == "outside range"
    assert error.filename == "range.js"
    assert error.stack =~ "RangeError: outside range"
  end

  test "matches Error hierarchy construction and prototype descriptors" do
    source =
      "(()=>{let empty=new Error();let plain=Error();let typed=TypeError('wrong');return [empty.toString(),Object.prototype.hasOwnProperty.call(empty,'message'),Object.prototype.hasOwnProperty.call(plain,'message'),typed.toString(),typed instanceof TypeError,typed instanceof Error,TypeError.prototype.constructor===TypeError]})()"

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok, ["Error", false, false, "TypeError: wrong", true, true, true]} =
             QuickBEAM.VM.eval(program)
  end

  test "normalizes uncaught type errors" do
    assert {:ok, program} = QuickBEAM.VM.compile("const value = 1; value()", filename: "type.js")

    assert {:error, %QuickBEAM.JSError{} = error} = QuickBEAM.VM.eval(program)
    assert error.name == "TypeError"
    assert error.message =~ "is not a function"
    assert error.filename == "type.js"
    assert error.stack =~ "type.js:1:"
  end

  test "normalizes asynchronous handler failures without exposing Elixir frames" do
    source = "(async function load(){return await Beam.call('fail')})()"
    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: "async.js")

    handler = fn [] -> raise "database unavailable" end

    assert {:error, %QuickBEAM.JSError{} = error} =
             QuickBEAM.VM.eval(program, handlers: %{"fail" => handler})

    assert error.name == "Error"
    assert error.message == "database unavailable"
    assert error.stack =~ "at load (async.js:1:"
    refute error.stack =~ "lib/quickbeam"
    refute error.stack =~ "error_test.exs"
  end

  test "keeps infrastructure and resource failures distinct from JavaScript errors" do
    assert {:ok, loop} = QuickBEAM.VM.compile("while(true) {}")

    assert {:error, {:limit_exceeded, :steps, 10}} =
             QuickBEAM.VM.eval(loop, max_steps: 10)

    assert {:ok, unsupported} = QuickBEAM.VM.compile("class Unsupported {}")

    assert {:error, {:unsupported_opcode, :define_class, _operands}} =
             QuickBEAM.VM.eval(unsupported)
  end
end
