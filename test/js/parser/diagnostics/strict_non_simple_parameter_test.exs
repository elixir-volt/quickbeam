defmodule QuickBEAM.JS.Parser.Diagnostics.StrictNonSimpleParameterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects strict function bodies with non-simple parameters" do
    for source <- [
          "function f(a = 1) { 'use strict'; }",
          "function f({ a }) { 'use strict'; }",
          "function f(...rest) { 'use strict'; }",
          "({ a = 1 }) => { 'use strict'; };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "use strict not allowed with non-simple parameters")
             )
    end
  end
end
