defmodule QuickBEAM.JS.Parser.Diagnostics.StrictFunctionExpressionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate function expression parameters in strict code" do
    for source <- [
          ~S|"use strict"; (function (param, param) {});|,
          ~S|"use strict"; (function (a, b, a) {});|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "duplicate parameter name not allowed in strict mode")
             )
    end
  end

  test "rejects restricted function expression names in strict code" do
    for source <- [
          ~S|"use strict"; (function eval() {});|,
          ~S|"use strict"; (function arguments() {});|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
    end
  end
end
