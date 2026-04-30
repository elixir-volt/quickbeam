defmodule QuickBEAM.JS.Parser.Diagnostics.BreakLabelFunctionExpressionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "validates break labels inside function expressions" do
    source =
      "(function(){ outer: do { break missing; } while (false); missing: do {} while(false); })();"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "undefined break label"))
  end

  test "keeps return valid inside function expressions" do
    assert {:ok, %AST.Program{}} = Parser.parse("(function(){ return; })();")
  end
end
