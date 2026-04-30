defmodule QuickBEAM.JS.Parser.Literals.HexNumericSeparatorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows hex numeric separators with e-like digits" do
    for source <- ["0xa_a;", "0xe_e;", "0xA_A;", "0xE_En;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
