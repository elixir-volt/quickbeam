defmodule QuickBEAM.DSLTest do
  use ExUnit.Case, async: true

  import QuickBEAM.Value

  test "sandbox presets return inspectable runtime options" do
    assert Keyword.fetch!(QuickBEAM.sandbox(:strict), :apis) == false
    assert Keyword.fetch!(QuickBEAM.sandbox(:browser), :apis) == [:browser]
    assert Keyword.fetch!(QuickBEAM.sandbox(:node), :apis) == [:node]
    assert Keyword.fetch!(QuickBEAM.sandbox(:bare), :apis) == false
    assert Keyword.fetch!(QuickBEAM.sandbox(:strict, memory_limit: 123), :memory_limit) == 123
  end

  test "new expands sandbox presets" do
    {:ok, rt} = QuickBEAM.new(sandbox: :bare)
    assert {:ok, 3} = QuickBEAM.eval(rt, "1 + 2")
    QuickBEAM.stop(rt)
  end

  test "public value helpers describe BEAM-mode JS values" do
    object = {:obj, make_ref()}
    symbol = {:symbol, "name", make_ref()}
    bigint = QuickBEAM.Value.bigint(123)

    assert is_object(object)
    assert QuickBEAM.Value.object?(object)
    assert is_symbol(symbol)
    assert QuickBEAM.Value.symbol?(symbol)
    assert QuickBEAM.Value.symbol_description(symbol) == "name"
    assert is_bigint(bigint)
    assert QuickBEAM.Value.bigint?(bigint)
    assert is_nullish(:undefined)
  end
end
