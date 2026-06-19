defmodule QuickBEAM.JS.Parser.Literals.RegexpLineTerminatorDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects escaped line terminators in regexp literals" do
    for source <- ["/\\\n/", "/a\\\n/", "/\\\u2028/", "/a\\\u2029/"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "unterminated regular expression literal"))
    end
  end
end
