defmodule QuickBEAM.JS.Parser.ControlFlow.TryCatchTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS try catch syntax used by constructor/delete tests" do
    source = """
    try { new G() } catch (ex_) { ex = ex_ }
    try { delete null.a; } catch(e) { err = (e instanceof TypeError); } finally { err = err; }
    """

    assert {:ok, %AST.Program{body: [ctor_try, delete_try]}} = Parser.parse(source)

    assert %AST.TryStatement{
             block: %AST.BlockStatement{},
             handler: %AST.CatchClause{param: %AST.Identifier{name: "ex_"}},
             finalizer: nil
           } = ctor_try

    assert %AST.TryStatement{
             handler: %AST.CatchClause{param: %AST.Identifier{name: "e"}},
             finalizer: %AST.BlockStatement{}
           } = delete_try
  end
end
