defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleClassNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module class arguments binding name diagnostics" do
    assert {:error,
            %AST.Program{
              source_type: :module,
              body: [%AST.ClassDeclaration{id: %AST.Identifier{name: "arguments"}}]
            }, errors} =
             Parser.parse("class arguments {}", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
