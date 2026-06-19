defmodule QuickBEAM.JS.Parser.Diagnostics.StrictFunctionNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict restricted function declaration name diagnostics" do
    source = ~S|function eval() { "use strict"; return 1; }|

    assert {:error,
            %AST.Program{body: [%AST.FunctionDeclaration{id: %AST.Identifier{name: "eval"}}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "ports QuickJS strict restricted function expression name diagnostics" do
    source = ~S|value = function arguments() { "use strict"; return 1; };|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
