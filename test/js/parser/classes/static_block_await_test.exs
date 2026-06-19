defmodule QuickBEAM.JS.Parser.Classes.StaticBlockAwaitTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows await references in nested class constructor parameters inside static blocks" do
    source =
      "class C { static { new (class { constructor(x = await) { fromBody = await; } }); } }"

    assert {:ok, %AST.Program{}} = Parser.parse(source)
  end

  test "rejects await as a class binding name inside static blocks" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("class C { static { (class await {}); } }")

    assert Enum.any?(errors, &(&1.message == "expected class name"))
  end
end
