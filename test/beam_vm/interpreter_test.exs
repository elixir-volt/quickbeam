defmodule QuickBEAM.BeamVM.InterpreterTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.BeamVM.{Bytecode, Interpreter}

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  # Compile JS → decode → eval on BEAM
  defp eval_js(rt, code) do
    {:ok, bc} = QuickBEAM.compile(rt, code)
    {:ok, parsed} = Bytecode.decode(bc)
    Interpreter.eval(parsed.value, [], %{}, parsed.atoms)
  end

  # Same but return the raw result (unwrap {:ok, _})
  defp eval_js!(rt, code) do
    {:ok, result} = eval_js(rt, code)
    result
  end

  describe "arithmetic" do
    test "integer addition", %{rt: rt} do
      assert eval_js!(rt, "1 + 2") == 3
    end

    test "integer multiplication", %{rt: rt} do
      assert eval_js!(rt, "6 * 7") == 42
    end

    test "integer subtraction", %{rt: rt} do
      assert eval_js!(rt, "10 - 3") == 7
    end

    test "integer division", %{rt: rt} do
      assert eval_js!(rt, "10 / 3") == 10 / 3
    end

    test "complex arithmetic", %{rt: rt} do
      assert eval_js!(rt, "2 + 3 * 4") == 14
    end

    test "parenthesized expression", %{rt: rt} do
      assert eval_js!(rt, "(2 + 3) * 4") == 20
    end

    test "unary negation", %{rt: rt} do
      assert eval_js!(rt, "-42") == -42
    end
  end

  describe "comparisons" do
    test "less than", %{rt: rt} do
      assert eval_js!(rt, "1 < 2") == true
      assert eval_js!(rt, "2 < 1") == false
    end

    test "greater than", %{rt: rt} do
      assert eval_js!(rt, "2 > 1") == true
      assert eval_js!(rt, "1 > 2") == false
    end

    test "equality", %{rt: rt} do
      assert eval_js!(rt, "1 === 1") == true
      assert eval_js!(rt, "1 === 2") == false
    end

    test "inequality", %{rt: rt} do
      assert eval_js!(rt, "1 !== 2") == true
      assert eval_js!(rt, "1 !== 1") == false
    end
  end

  describe "variables and locals" do
    test "let binding", %{rt: rt} do
      assert eval_js!(rt, "{ let x = 42; x }") == 42
    end

    test "multiple bindings", %{rt: rt} do
      assert eval_js!(rt, "{ let a = 1; let b = 2; a + b }") == 3
    end

    test "reassignment", %{rt: rt} do
      assert eval_js!(rt, "{ let x = 1; x = 2; x }") == 2
    end
  end

  describe "control flow" do
    test "if true", %{rt: rt} do
      assert eval_js!(rt, "true ? 1 : 2") == 1
    end

    test "if false", %{rt: rt} do
      assert eval_js!(rt, "false ? 1 : 2") == 2
    end

    test "if with comparison", %{rt: rt} do
      assert eval_js!(rt, "{ let x = 5; if (x > 3) x; else 0 }") == 5
    end

    test "while loop", %{rt: rt} do
      code = "{ let s = 0; let i = 0; while (i < 10) { s = s + i; i = i + 1; } s }"
      assert eval_js!(rt, code) == 45
    end

    test "for loop", %{rt: rt} do
      code = "{ let s = 0; for (let i = 0; i < 5; i = i + 1) s = s + i; s }"
      assert eval_js!(rt, code) == 10
    end
  end

  describe "functions" do
    test "IIFE", %{rt: rt} do
      assert eval_js!(rt, "(function(){return 42})()") == 42
    end

    test "IIFE with args", %{rt: rt} do
      assert eval_js!(rt, "(function(a,b){return a+b})(3,4)") == 7
    end

    test "nested function", %{rt: rt} do
      code = "(function(){return (function(x){return x*2})(21)})()"
      assert eval_js!(rt, code) == 42
    end
  end

  describe "values" do
    test "null", %{rt: rt} do
      assert eval_js!(rt, "null") == nil
    end

    test "undefined", %{rt: rt} do
      assert eval_js!(rt, "undefined") == :undefined
    end

    test "true", %{rt: rt} do
      assert eval_js!(rt, "true") == true
    end

    test "false", %{rt: rt} do
      assert eval_js!(rt, "false") == false
    end

    test "string", %{rt: rt} do
      assert eval_js!(rt, ~s|"hello"|) == "hello"
    end
  end

  describe "bitwise" do
    test "AND", %{rt: rt} do
      assert eval_js!(rt, "0xFF & 0x0F") == 0x0F
    end

    test "OR", %{rt: rt} do
      assert eval_js!(rt, "0xF0 | 0x0F") == 0xFF
    end

    test "XOR", %{rt: rt} do
      assert eval_js!(rt, "0xFF ^ 0x0F") == 0xF0
    end

    test "left shift", %{rt: rt} do
      assert eval_js!(rt, "1 << 4") == 16
    end

    test "right shift", %{rt: rt} do
      assert eval_js!(rt, "16 >> 2") == 4
    end
  end

  describe "logical" do
    test "logical NOT", %{rt: rt} do
      assert eval_js!(rt, "!true") == false
      assert eval_js!(rt, "!false") == true
    end

    test "typeof", %{rt: rt} do
      assert eval_js!(rt, "typeof 42") == "number"
      assert eval_js!(rt, ~s|typeof "hello"|) == "string"
      assert eval_js!(rt, "typeof true") == "boolean"
      assert eval_js!(rt, "typeof undefined") == "undefined"
    end
  end

  describe "objects" do
    test "object literal property access", %{rt: rt} do
      assert eval_js!(rt, "({x: 1, y: 2}).x") == 1
    end

    test "object literal multiple properties", %{rt: rt} do
      assert eval_js!(rt, "({x: 1, y: 2}).y") == 2
    end

    test "object property set and get", %{rt: rt} do
      assert eval_js!(rt, "{ let o = {x: 1}; o.y = 2; o.x + o.y }") == 3
    end

    test "nested object", %{rt: rt} do
      assert eval_js!(rt, "({a: {b: 42}}).a.b") == 42
    end

    test "object with string value", %{rt: rt} do
      assert eval_js!(rt, ~s|({name: "test"}).name|) == "test"
    end
  end

  describe "arrays" do
    test "array literal index access", %{rt: rt} do
      assert eval_js!(rt, "[10, 20, 30][0]") == 10
    end

    test "array index access middle", %{rt: rt} do
      assert eval_js!(rt, "[10, 20, 30][2]") == 30
    end

    test "array length", %{rt: rt} do
      assert eval_js!(rt, "[1, 2, 3].length") == 3
    end

    test "empty array length", %{rt: rt} do
      assert eval_js!(rt, "[].length") == 0
    end

    test "array out of bounds", %{rt: rt} do
      assert eval_js!(rt, "[1,2,3][10]") == :undefined
    end
  end

  describe "closures" do
    test "simple closure captures variable", %{rt: rt} do
      code = "(function() { let x = 10; return (function() { return x })() })()"
      assert eval_js!(rt, code) == 10
    end

    test "closure with argument", %{rt: rt} do
      code = "(function(x) { return (function() { return x })() })(42)"
      assert eval_js!(rt, code) == 42
    end
  end

  describe "string operations" do
    test "string length", %{rt: rt} do
      assert eval_js!(rt, ~s|"hello".length|) == 5
    end

    test "empty string length", %{rt: rt} do
      assert eval_js!(rt, ~s|"".length|) == 0
    end

    test "string concatenation", %{rt: rt} do
      assert eval_js!(rt, ~s|"hello" + " " + "world"|) == "hello world"
    end

    test "string + number coercion", %{rt: rt} do
      assert eval_js!(rt, ~s|"num: " + 42|) == "num: 42"
    end
  end

  describe "modulo and power" do
    test "modulo", %{rt: rt} do
      assert eval_js!(rt, "10 % 3") == 1
    end

    test "power", %{rt: rt} do
      assert eval_js!(rt, "2 ** 10") == 1024.0
    end
  end

  describe "null and undefined operators" do
    test "null coalescing", %{rt: rt} do
      assert eval_js!(rt, "null ?? 42") == 42
    end

    test "null coalescing non-null", %{rt: rt} do
      assert eval_js!(rt, "1 ?? 42") == 1
    end

    test "optional chaining on null", %{rt: rt} do
      assert eval_js!(rt, "null?.x") == :undefined
    end

    test "is null check", %{rt: rt} do
      assert eval_js!(rt, "null === null") == true
    end

    test "undefined === undefined", %{rt: rt} do
      assert eval_js!(rt, "undefined === undefined") == true
    end

    test "null !== undefined (strict)", %{rt: rt} do
      assert eval_js!(rt, "null !== undefined") == true
    end
  end

  describe "short-circuit evaluation" do
    test "logical AND truthy", %{rt: rt} do
      assert eval_js!(rt, "1 && 2") == 2
    end

    test "logical AND falsy", %{rt: rt} do
      assert eval_js!(rt, "0 && 2") == 0
    end

    test "logical OR truthy", %{rt: rt} do
      assert eval_js!(rt, "1 || 2") == 1
    end

    test "logical OR falsy", %{rt: rt} do
      assert eval_js!(rt, "0 || 42") == 42
    end
  end

  describe "ternary operator" do
    test "ternary true branch", %{rt: rt} do
      assert eval_js!(rt, "true ? 'yes' : 'no'") == "yes"
    end

    test "ternary false branch", %{rt: rt} do
      assert eval_js!(rt, "false ? 'yes' : 'no'") == "no"
    end

    test "ternary with expression", %{rt: rt} do
      assert eval_js!(rt, "(1 > 2) ? 10 : 20") == 20
    end
  end

  describe "complex expressions" do
    test "nested function calls", %{rt: rt} do
      code = "(function(a,b){return a+b})((function(){return 3})(), 4)"
      assert eval_js!(rt, code) == 7
    end

    test "fibonacci", %{rt: rt} do
      code = "(function fib(n) { if (n <= 1) return n; return fib(n-1) + fib(n-2) })(10)"
      assert eval_js!(rt, code) == 55
    end

    test "sum loop IIFE", %{rt: rt} do
      code = "(function(n){let s=0;for(let i=0;i<n;i++)s+=i;return s})(100)"
      assert eval_js!(rt, code) == 4950
    end

    test "factorial", %{rt: rt} do
      code = "(function f(n){if(n<=1)return 1;return n*f(n-1)})(6)"
      assert eval_js!(rt, code) == 720
    end
  end
end
