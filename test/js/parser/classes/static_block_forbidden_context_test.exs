defmodule QuickBEAM.JS.Parser.Classes.StaticBlockForbiddenContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects return, await, yield, and arguments across static block boundaries" do
    for source <- [
          "function f() { class C { static { return; } } }",
          "async function f() { class C { static { await 0; } } }",
          "function *g() { class C { static { yield; } } }",
          "class C { static { const await = 0; } }",
          "class C { static { (class { [arguments]() {} }); } }"
        ] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
