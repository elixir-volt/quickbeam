defmodule QuickBEAM.JS.Parser.ControlFlow.ConditionalNoInTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects in expressions in conditional alternate inside for init" do
    source = "for (true ? 0 : 0 in {}; false; ) ;"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert errors != []
  end

  test "allows in expressions in conditional consequent inside for init" do
    source = "for (true ? 0 in {} : 0; false; ) ;"

    assert {:ok, %AST.Program{}} = Parser.parse(source)
  end
end
