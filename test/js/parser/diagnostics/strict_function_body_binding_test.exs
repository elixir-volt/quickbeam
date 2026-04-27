defmodule QuickBEAM.JS.Parser.Diagnostics.StrictFunctionBodyBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict function body eval binding diagnostics" do
    source = ~S|function f() { "use strict"; var eval; }|

    assert {:error,
            %AST.Program{body: [%AST.FunctionDeclaration{id: %AST.Identifier{name: "f"}}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "ports QuickJS strict function body arguments declaration diagnostics" do
    source = ~S|function f() { "use strict"; function arguments() {} }|

    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
