defmodule QuickBEAM.JS.Parser.Diagnostics.SyntaxErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS syntax errors for incomplete control statements" do
    for source <- ["do", "do;", "do{}", "if", "if\n", "if 1", "if ;", "if abc", "while"] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end

  test "ports QuickJS syntax errors for incomplete class and switch statements" do
    for source <- ["class", "class C", "switch", "switch (x)", "try {}"] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
