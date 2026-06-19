defmodule QuickBEAM.JS.Parser.ControlFlow.OptionalCatchBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible optional catch binding syntax" do
    source = """
    try {} catch {}
    try {} catch (e) {} finally {}
    """

    assert {:ok, %AST.Program{body: [optional_catch, catch_finally]}} = Parser.parse(source)

    assert %AST.TryStatement{handler: %AST.CatchClause{param: nil}, finalizer: nil} =
             optional_catch

    assert %AST.TryStatement{
             handler: %AST.CatchClause{param: %AST.Identifier{name: "e"}},
             finalizer: %AST.BlockStatement{}
           } = catch_finally
  end
end
