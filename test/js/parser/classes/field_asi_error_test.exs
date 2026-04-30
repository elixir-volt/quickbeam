defmodule QuickBEAM.JS.Parser.Classes.FieldASIErrorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "recovers from class field ASI continuation errors" do
    for source <- [
          ~S|var C = class { x = "string"
          [0]() {} }|,
          "var C = class { x = 42\n*gen() {} }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end
end
