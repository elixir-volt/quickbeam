defmodule QuickBEAM.JS.Parser.Diagnostics.RestParameterErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS rest parameter position diagnostics" do
    for source <- ["function f(...rest, extra) {}", "(...rest, extra) => rest;"] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
