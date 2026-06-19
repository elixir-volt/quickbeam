defmodule QuickBEAM.JS.Parser.Diagnostics.RestParameterTrailingCommaErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS rest parameter trailing comma diagnostics" do
    for source <- ["function f(...rest,) {}", "(...rest,) => rest;"] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
