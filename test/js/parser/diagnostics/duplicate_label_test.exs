defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicateLabelTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate nested label diagnostics" do
    assert {:error, %AST.Program{body: [%AST.LabeledStatement{}]}, errors} =
             Parser.parse("label: label: statement;")

    assert Enum.any?(errors, &(&1.message == "duplicate label"))
  end

  test "ports QuickJS duplicate label inside labelled loop diagnostics" do
    source = "label: while (value) { label: break label; }"

    assert {:error, %AST.Program{body: [%AST.LabeledStatement{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "duplicate label"))
  end
end
