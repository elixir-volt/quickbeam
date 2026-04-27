defmodule QuickBEAM.JS.Parser.Diagnostics.ExportSourceErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS export source diagnostics" do
    for source <- [
          ~S(export { value } from dep;),
          ~S(export * from dep;),
          ~S(export * as ns from dep;)
        ] do
      assert {:error, %AST.Program{source_type: :module}, errors} =
               Parser.parse(source, source_type: :module)

      assert Enum.any?(errors, &(&1.message == "expected module source"))
    end
  end
end
