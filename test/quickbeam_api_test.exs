defmodule QuickBEAM.APITest do
  use ExUnit.Case, async: false

  import QuickBEAM

  defmodule Tools do
    use QuickBEAM.API, scope: "tools.math"

    js(double(n), do: n * 2)

    js add(a, b), runtime do
      assert is_pid(runtime)
      a + b
    end

    def install(_runtime, _scope, _data), do: "globalThis.tools.installed = true"
  end

  defmodule FlexibleTools do
    use QuickBEAM.API, scope: "flex"

    js(label(value) when is_integer(value), do: "int:#{value}")
    js(label(value) when is_binary(value), do: "str:#{value}")
    js(sum(a, b), do: a + b)
    js(sum(a, b, c), do: a + b + c)

    @variadic true
    js(join(args), do: Enum.join(args, ":"))

    def install(%QuickBEAM.API.Context{}), do: ~JS"globalThis.flexInstalled = true"c
  end

  defmodule FailingInstall do
    use QuickBEAM.API, scope: "bad"
    js(ok(), do: true)
    def install(_runtime, _scope, _data), do: "throw new Error('install failed')"
  end

  defmodule RaisingInstall do
    use QuickBEAM.API, scope: "raising"
    js(ok(), do: true)
    def install(_runtime, _scope, _data), do: raise("boom")
  end

  defmodule DataTools do
    use QuickBEAM.API, scope: "dataTools"
    js(pair(), do: {1, 2})
    def install(%QuickBEAM.API.Context{data: data}), do: "globalThis.loadedData = #{length(data)}"
  end

  test "~JS validates source and c modifier returns a chunk" do
    assert ~JS"1 + 2" == "1 + 2"
    assert %QuickBEAM.Chunk{source: "1 + 2"} = ~JS"1 + 2"c
  end

  test "parse and compile chunks can be evaluated" do
    assert {:ok, %QuickBEAM.Chunk{source: "1 + 2"}} = QuickBEAM.parse_chunk("1 + 2")
    assert {:error, %QuickBEAM.JS.Error{name: "SyntaxError"}} = QuickBEAM.parse_chunk("let =")

    {:ok, rt} = QuickBEAM.start(apis: false)
    {:ok, chunk} = QuickBEAM.compile_chunk(rt, "x + 2")

    assert {:ok, 3} = QuickBEAM.eval(rt, chunk, vars: %{"x" => 1})

    QuickBEAM.stop(rt)
  end

  test "load_api exposes js functions under scope" do
    {:ok, rt} = QuickBEAM.start()

    assert :ok = QuickBEAM.load_api(rt, Tools)
    assert {:ok, true} = QuickBEAM.eval(rt, "tools.installed")
    assert {:ok, 10} = QuickBEAM.eval(rt, "tools.math.double(5)")
    assert {:ok, 7} = QuickBEAM.eval(rt, "tools.math.add(3, 4)")

    QuickBEAM.stop(rt)
  end

  test "load_api supports apis false, scope overrides, clauses, arities, variadic and install context" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    assert :ok = QuickBEAM.load_api(rt, FlexibleTools, scope: "custom.flex")
    assert {:ok, true} = QuickBEAM.eval(rt, "flexInstalled")
    assert {:ok, "int:1"} = QuickBEAM.eval(rt, "custom.flex.label(1)")
    assert {:ok, "str:x"} = QuickBEAM.eval(rt, "custom.flex.label('x')")
    assert {:ok, 3} = QuickBEAM.eval(rt, "custom.flex.sum(1, 2)")
    assert {:ok, 6} = QuickBEAM.eval(rt, "custom.flex.sum(1, 2, 3)")
    assert {:ok, "a:b:c"} = QuickBEAM.eval(rt, "custom.flex.join('a', 'b', 'c')")

    QuickBEAM.stop(rt)
  end

  test "load_api accepts non-keyword list data and preserves host tuple returns" do
    {:ok, rt} = QuickBEAM.start()

    assert :ok = QuickBEAM.load_api(rt, DataTools, [1, 2, 3])
    assert {:ok, 3} = QuickBEAM.eval(rt, "loadedData")
    assert {:ok, [1, 2]} = QuickBEAM.eval(rt, "dataTools.pair()")

    QuickBEAM.stop(rt)
  end

  test "load_api replaces non-object scope segments and rolls back handlers on install failure" do
    {:ok, rt} = QuickBEAM.start()

    assert {:ok, true} = QuickBEAM.eval(rt, "globalThis.bad = true")

    assert {:error, %QuickBEAM.JS.Error{message: "install failed"}} =
             QuickBEAM.load_api(rt, FailingInstall)

    assert {:error, %QuickBEAM.JS.Error{message: message}} =
             QuickBEAM.eval(
               rt,
               "Beam.callSync('__quickbeam_api__:QuickBEAM.APITest.FailingInstall:ok')"
             )

    assert message =~ "Unknown handler"

    QuickBEAM.stop(rt)
  end

  test "load_api rolls back handlers on raised install and keeps preexisting globals user-visible" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    assert {:ok, 42} = QuickBEAM.eval(rt, "globalThis.beforeApi = 42")
    assert_raise RuntimeError, "boom", fn -> QuickBEAM.load_api(rt, RaisingInstall) end

    assert {:error, %QuickBEAM.JS.Error{message: message}} =
             QuickBEAM.eval(
               rt,
               "Beam.callSync('__quickbeam_api__:QuickBEAM.APITest.RaisingInstall:ok')"
             )

    assert message =~ "Unknown handler"
    assert {:ok, 42} = QuickBEAM.get_global(rt, "beforeApi", user_only: true)

    QuickBEAM.stop(rt)
  end

  test "load_api rejects unsafe scope segments" do
    {:ok, rt} = QuickBEAM.start()

    assert_raise ArgumentError, ~r/unsafe QuickBEAM API scope segment/, fn ->
      QuickBEAM.load_api(rt, Tools, scope: "__proto__.polluted")
    end

    QuickBEAM.stop(rt)
  end
end
