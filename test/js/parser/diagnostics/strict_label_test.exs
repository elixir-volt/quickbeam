defmodule QuickBEAM.JS.Parser.Diagnostics.StrictLabelTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects restricted labels in strict code" do
    for source <- ["\"use strict\"; yield: 1;", "\"use strict\"; y\\u0069eld: 1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end
end
