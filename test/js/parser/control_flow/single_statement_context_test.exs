defmodule QuickBEAM.JS.Parser.ControlFlow.SingleStatementContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects lexical and class declarations in single-statement contexts" do
    cases = [
      {"if (x) let y = 1;", "lexical declarations can't appear in single-statement context"},
      {"while (x) const y = 1;", "lexical declarations can't appear in single-statement context"},
      {"do let y = 1; while (x);",
       "lexical declarations can't appear in single-statement context"},
      {"with (x) const y = 1;", "lexical declarations can't appear in single-statement context"},
      {"while (x) class C {}", "class declarations can't appear in single-statement context"},
      {"label: const y = 1;", "lexical declarations can't appear in single-statement context"},
      {"label: async function f() {}",
       "function declarations can't appear in single-statement context"}
    ]

    for {source, message} <- cases do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == message))
    end
  end
end
