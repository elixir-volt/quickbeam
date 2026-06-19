defmodule QuickBEAM.JS.Parser.ControlFlow.ForInOfSingleStatementContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects declarations as for-in and for-of single-statement bodies" do
    cases = [
      {"for (x in y) function f() {}",
       "function declarations can't appear in single-statement context"},
      {"for (x of y) async function f() {}",
       "function declarations can't appear in single-statement context"},
      {"for (x in y) class C {}", "class declarations can't appear in single-statement context"},
      {"for (x of y) let z;", "lexical declarations can't appear in single-statement context"},
      {"for await (x of y) const z = 1;",
       "lexical declarations can't appear in single-statement context"}
    ]

    for {source, message} <- cases do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == message))
    end
  end
end
