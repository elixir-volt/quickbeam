defmodule QuickBEAM.JS.Parser.Classes.ConstructorAccessorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS rejection of class accessors named constructor" do
    for source <- [
          "class C { get constructor() { return 1; } }",
          "class C { set constructor(value) { this.value = value; } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid method name"))
    end
  end
end
