defmodule QuickBEAM.JS.Parser.Classes.ConstructorAccessorNotDuplicateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS rejection of constructor plus constructor accessor syntax" do
    source = "class C { constructor() {} get constructor() { return 1; } }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "invalid method name"))
  end
end
