defmodule QuickBEAM.JS.Parser.Classes.StrictNonSimpleMethodParameterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects strict method bodies with non-simple parameters" do
    for source <- [
          "class C { async *m({ value }) { 'use strict'; } }",
          "class C { static async *m(...rest) { 'use strict'; } }",
          "class C { m(value = 1) { 'use strict'; } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "use strict not allowed with non-simple parameters")
             )
    end
  end
end
