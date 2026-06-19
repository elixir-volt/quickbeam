defmodule QuickBEAM.JS.Parser.Diagnostics.StringImportLocalErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS string import local-name diagnostics" do
    source = ~S(import { "external-name" as "local-name" } from "dep";)

    assert {:error, %AST.Program{source_type: :module}, [_ | _]} =
             Parser.parse(source, source_type: :module)
  end
end
