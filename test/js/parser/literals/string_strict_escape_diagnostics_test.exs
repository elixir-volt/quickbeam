defmodule QuickBEAM.JS.Parser.Literals.StringStrictEscapeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects non-octal decimal escapes in strict code" do
    for source <- [
          ~S|"use strict"; "\8";|,
          ~S|"use strict"; "\9";|,
          ~S|function f() { "\8"; "use strict"; }|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "octal escape sequence not allowed in strict mode")
             )
    end
  end
end
