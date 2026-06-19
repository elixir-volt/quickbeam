defmodule QuickBEAM.JS.Parser.Literals.TemplateEscapeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid escapes in untagged templates" do
    for source <- ["`\\u0`;", "`\\x0`;", "`\\8`;", "`\\00`;", "`\\u{Z}`;", "`\\u{10FFFFF}`;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid template escape sequence"))
    end
  end

  test "keeps invalid escapes inside tagged templates as syntax" do
    assert {:ok, %AST.Program{}} = Parser.parse("tag`\\u0`;")
  end
end
