defmodule QuickBEAM.BeamVM.BytecodeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.BeamVM.Bytecode

  setup do
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  # Helper: compile JS code and decode the bytecode.
  # The top-level is always an eval wrapper; extract the first Function from cpool.
  defp compile_and_decode(rt, code) do
    {:ok, bc} = QuickBEAM.compile(rt, code)
    {:ok, parsed} = Bytecode.decode(bc)
    parsed
  end

  # Get the first user function from the constant pool (skipping the eval wrapper)
  defp user_function(parsed) do
    fun = parsed.value
    # For simple expressions, the top-level function IS the eval wrapper.
    # The actual code is in the top-level function itself.
    # For function expressions, the user function is in the cpool.
    inner = for %Bytecode.Function{} = f <- fun.constants, do: f

    case inner do
      [first | _] -> first
      [] -> fun
    end
  end

  describe "decode/1 structure" do
    test "parses version and atom table", %{rt: rt} do
      parsed = compile_and_decode(rt, "42")
      assert parsed.version == 24
      assert is_tuple(parsed.atoms)
    end

    test "top-level is always a Function", %{rt: rt} do
      parsed = compile_and_decode(rt, "42")
      assert is_struct(parsed.value, Bytecode.Function)
    end
  end

  describe "simple expressions" do
    test "integer literal", %{rt: rt} do
      parsed = compile_and_decode(rt, "42")
      fun = parsed.value
      assert is_struct(fun, Bytecode.Function)
      assert fun.arg_count == 0
      assert byte_size(fun.byte_code) > 0
    end

    test "string literal", %{rt: rt} do
      parsed = compile_and_decode(rt, ~s|"hello"|)
      fun = parsed.value
      assert is_struct(fun, Bytecode.Function)
      # String literals are pushed by bytecode ops, not stored in cpool for simple cases
      assert fun.stack_size > 0
      assert byte_size(fun.byte_code) > 0
    end

    test "boolean, null, undefined", %{rt: rt} do
      for code <- ["true", "null", "undefined"] do
        parsed = compile_and_decode(rt, code)
        assert is_struct(parsed.value, Bytecode.Function)
      end
    end
  end

  describe "functions" do
    test "simple add function", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(a,b){return a+b})")
      fun = user_function(parsed)

      assert fun.arg_count == 2
      assert fun.var_count == 0
      assert fun.stack_size > 0
      assert byte_size(fun.byte_code) > 0
    end

    test "function with locals", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(n){let s=0;for(let i=0;i<n;i++)s+=i;return s})")
      fun = user_function(parsed)

      assert fun.arg_count == 1
      local_names = Enum.map(fun.locals, & &1.name)
      assert Enum.any?(local_names, &(&1 == "s"))
      assert Enum.any?(local_names, &(&1 == "i"))
    end

    test "closure", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(){let x=1;return function(){return x}})")
      outer = user_function(parsed)
      inner_funs = for %Bytecode.Function{} = f <- outer.constants, do: f
      assert inner_funs != []

      inner = hd(inner_funs)
      assert inner.closure_vars != []
      assert inner.closure_vars |> hd() |> Map.get(:name) == "x"
    end

    test "recursive function", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function f(n){return n<=1?n:f(n-1)+f(n-2)})")
      fun = user_function(parsed)
      # Named function — name should be "f"
      assert fun.name == "f"
    end
  end

  describe "objects and arrays" do
    test "object literal", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(){return {a:1,b:2}})")
      fun = user_function(parsed)
      assert is_list(fun.constants)
    end

    test "array literal", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(){return [1,2,3]})")
      fun = user_function(parsed)
      assert is_struct(fun, Bytecode.Function)
    end
  end

  describe "control flow" do
    test "if/else", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(x){if(x>0)return 1;else return -1})")
      fun = user_function(parsed)
      assert fun.arg_count == 1
    end

    test "try/catch", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(){try{throw 1}catch(e){return e}})")
      fun = user_function(parsed)
      assert is_struct(fun, Bytecode.Function)
    end

    test "for/in", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(o){let s=0;for(let k in o)s+=o[k];return s})")
      fun = user_function(parsed)
      assert fun.arg_count == 1
    end
  end

  describe "advanced features" do
    test "arrow functions in map", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(){return [1,2,3].map(x=>x*2)})")
      fun = user_function(parsed)
      inner_funs = for %Bytecode.Function{} = f <- fun.constants, do: f
      assert inner_funs != []
    end

    test "class", %{rt: rt} do
      parsed =
        compile_and_decode(rt, "(function(){class A{constructor(x){this.x=x}} return new A(1)})")

      fun = user_function(parsed)
      assert is_struct(fun, Bytecode.Function)
    end

    test "destructuring", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function({a,b}){return a+b})")
      fun = user_function(parsed)
      assert fun.arg_count == 1
    end

    test "template literal", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(name){return `hello ${name}`})")
      fun = user_function(parsed)
      assert fun.arg_count == 1
    end

    test "async function", %{rt: rt} do
      parsed = compile_and_decode(rt, "(async function(){return await 42})")
      fun = user_function(parsed)
      assert fun.func_kind in [2, 3]
    end
  end

  describe "error cases" do
    test "bad version", %{rt: rt} do
      {:ok, bc} = QuickBEAM.compile(rt, "42")
      bad_bc = <<0, binary_part(bc, 1, byte_size(bc) - 1)::binary>>
      assert {:error, {:bad_version, 0}} = Bytecode.decode(bad_bc)
    end

    test "truncated data" do
      assert {:error, _} = Bytecode.decode(<<24, 0, 0, 0, 0>>)
    end

    test "empty binary" do
      assert {:error, _} = Bytecode.decode(<<>>)
    end
  end

  describe "atoms" do
    test "atom table is populated", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(a,b){return a+b})")
      atom_list = Tuple.to_list(parsed.atoms)
      assert "a" in atom_list
      assert "b" in atom_list
    end
  end

  describe "locals" do
    test "var defs have correct names", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(x){let y=1;let z=2;return x+y+z})")
      fun = user_function(parsed)
      names = Enum.map(fun.locals, & &1.name)
      assert "x" in names
      assert "y" in names
      assert "z" in names
    end

    test "let vs var vs const", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(){let a=1;var b=2;const c=3;return a+b+c})")
      fun = user_function(parsed)
      locals_by_name = Map.new(fun.locals, &{&1.name, &1})
      assert locals_by_name["a"].is_lexical
      assert not locals_by_name["b"].is_lexical
      assert locals_by_name["c"].is_const
    end
  end
end
