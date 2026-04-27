defmodule QuickBEAM.JS.Parser.Diagnostics.ImportTrailingCommaErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS default import trailing comma diagnostics" do
    assert {:error, %AST.Program{source_type: :module}, errors} =
             Parser.parse(~S(import defaultValue, from "dep";), source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected import specifier"))
  end
end
