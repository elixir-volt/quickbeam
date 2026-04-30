defmodule QuickBEAM.JS.Parser.Expressions.ObjectStrictAccessorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects future reserved assignments in strict accessor bodies" do
    for source <- [
          ~S|({ get value() { "use strict"; public = 1; } });|,
          ~S|({ set value(v) { "use strict"; public = 1; } });|,
          ~S|"use strict"; void { get value() { public = 1; } };|,
          ~S|"use strict"; void { set value(v) { public = 1; } };|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
    end
  end

  test "rejects restricted setter parameters in strict programs" do
    for source <- [
          ~S|"use strict"; ({ set value(eval) {} });|,
          ~S|"use strict"; ({ set value(arguments) {} });|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
    end
  end
end
