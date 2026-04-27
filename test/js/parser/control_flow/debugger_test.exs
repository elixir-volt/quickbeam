defmodule QuickBEAM.JS.Parser.ControlFlow.DebuggerTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible debugger statement syntax" do
    assert {:ok, %AST.Program{body: [%AST.DebuggerStatement{}]}} = Parser.parse("debugger;")
  end
end
