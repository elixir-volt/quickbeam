defmodule QuickBEAM.JS.Parser.Classes.NonConstructorMethodNamesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS rejection of non-constructor methods named constructor" do
    for source <- [
          "class C { *constructor() { yield 1; } }",
          "class C { async constructor() { return 2; } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid method name"))
    end
  end
end
