defmodule QuickBEAM.APITest do
  use ExUnit.Case, async: false

  import QuickBEAM

  defmodule Tools do
    use QuickBEAM.API, scope: "tools.math"

    defjs(double(n), do: n * 2)

    defjs add(a, b), runtime do
      assert is_pid(runtime)
      a + b
    end

    def install(_runtime, _scope, _data), do: "globalThis.tools.installed = true"
  end

  test "~JS validates source and c modifier returns a chunk" do
    assert ~JS"1 + 2" == "1 + 2"
    assert %QuickBEAM.Chunk{source: "1 + 2"} = ~JS"1 + 2"c
  end

  test "compiled chunks can be evaluated" do
    {:ok, rt} = QuickBEAM.start(apis: false)
    {:ok, chunk} = QuickBEAM.compile_chunk(rt, "1 + 2")

    assert {:ok, 3} = QuickBEAM.eval(rt, chunk)

    QuickBEAM.stop(rt)
  end

  test "load_api exposes defjs functions under scope" do
    {:ok, rt} = QuickBEAM.start()

    assert :ok = QuickBEAM.load_api(rt, Tools)
    assert {:ok, true} = QuickBEAM.eval(rt, "tools.installed")
    assert {:ok, 10} = QuickBEAM.eval(rt, "tools.math.double(5)")
    assert {:ok, 7} = QuickBEAM.eval(rt, "tools.math.add(3, 4)")

    QuickBEAM.stop(rt)
  end
end
