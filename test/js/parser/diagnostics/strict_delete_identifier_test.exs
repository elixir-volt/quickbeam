defmodule QuickBEAM.JS.Parser.Diagnostics.StrictDeleteIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict delete identifier diagnostics" do
    source = ~S|"use strict"; delete value;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "delete of identifier not allowed in strict mode"))
  end

  test "ports QuickJS strict delete member allowance" do
    source = ~S|"use strict"; delete object.value;|

    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]}} =
             Parser.parse(source)
  end
end
