defmodule QuickBEAM.JS.Parser.Diagnostics.StrictRestrictedUpdateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict eval postfix update target diagnostics" do
    source = ~S|"use strict"; eval++;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end

  test "ports QuickJS strict arguments prefix update target diagnostics" do
    source = ~S|function f() { "use strict"; ++arguments; }|

    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end
end
