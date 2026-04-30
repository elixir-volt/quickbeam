defmodule QuickBEAM.JS.Parser.Literals.RegexpPropertyEscapeDiagnosticsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS malformed unicode property escape diagnostics" do
    for source <- [~S(pattern = /\p/u;), ~S(pattern = /\p{Script/u;), ~S(pattern = /\p{}/u;)] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert [_ | _] = errors
    end
  end

  test "ports QuickJS binary property with explicit value diagnostics" do
    for source <- [~S(pattern = /\p{ASCII=Yes}/u;), ~S(pattern = /\P{Alphabetic=No}/u;)] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "unknown unicode property name"))
    end
  end

  test "ports QuickJS escaped property escape repetition diagnostics" do
    assert {:error, %AST.Program{}, errors} = Parser.parse(~S(pattern = /\\p{ASCII}/u;))
    assert Enum.any?(errors, &(&1.message == "invalid repetition count"))
  end

  test "preserves valid unicode property escapes" do
    for source <- [~S(pattern = /\p{Script=Greek}/u;), ~S(pattern = /\p{ASCII}/u;)] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
