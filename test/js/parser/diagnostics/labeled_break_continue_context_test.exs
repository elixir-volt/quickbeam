defmodule QuickBEAM.JS.Parser.Diagnostics.LabeledBreakContinueContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS undefined break label diagnostics" do
    assert {:error, %AST.Program{body: [%AST.BreakStatement{}]}, errors} =
             Parser.parse("break missing;")

    assert Enum.any?(errors, &(&1.message == "undefined break label"))
  end

  test "ports QuickJS continue to non-iteration label diagnostics" do
    source = "label: { continue label; }"

    assert {:error, %AST.Program{body: [%AST.LabeledStatement{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "undefined or non-iteration continue label"))
  end

  test "ports QuickJS continue to iteration label allowance" do
    source = "loop: while (value) { continue loop; }"

    assert {:ok, %AST.Program{body: [%AST.LabeledStatement{}]}} = Parser.parse(source)
  end
end
