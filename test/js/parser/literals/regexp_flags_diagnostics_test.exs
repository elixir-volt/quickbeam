defmodule QuickBEAM.JS.Parser.Literals.RegexpFlagsDiagnosticsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS invalid regexp flag diagnostics" do
    for source <- [~S(pattern = /./uv;)] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid regular expression flags"))
    end
  end
end
