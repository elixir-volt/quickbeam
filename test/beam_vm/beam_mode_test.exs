defmodule QuickBEAM.BeamModeTest do
  use ExUnit.Case, async: true

  setup_all do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  defp eval_beam(rt, code) do
    QuickBEAM.eval(rt, code, mode: :beam)
  end

  describe "basic types (beam mode)" do
    test "numbers", %{rt: rt} do
      assert {:ok, 3} = eval_beam(rt, "1 + 2")
      assert {:ok, 42} = eval_beam(rt, "42")
      assert {:ok, 3.14} = eval_beam(rt, "3.14")
    end

    test "booleans", %{rt: rt} do
      assert {:ok, true} = eval_beam(rt, "true")
      assert {:ok, false} = eval_beam(rt, "false")
    end

    test "null and undefined", %{rt: rt} do
      assert {:ok, nil} = eval_beam(rt, "null")
      assert {:ok, nil} = eval_beam(rt, "undefined")
    end

    test "strings", %{rt: rt} do
      assert {:ok, "hello"} = eval_beam(rt, ~s["hello"])
      assert {:ok, ""} = eval_beam(rt, ~s[""])
      assert {:ok, "hello world"} = eval_beam(rt, ~s["hello world"])
    end
  end

  describe "arithmetic" do
    test "operations", %{rt: rt} do
      assert {:ok, 6} = eval_beam(rt, "2 * 3")
      assert {:ok, 7} = eval_beam(rt, "10 - 3")
      assert {:ok, 5.0} = eval_beam(rt, "10 / 2")
      assert {:ok, 1} = eval_beam(rt, "10 % 3")
    end

    test "precedence", %{rt: rt} do
      assert {:ok, 14} = eval_beam(rt, "2 + 3 * 4")
      assert {:ok, 20} = eval_beam(rt, "(2 + 3) * 4")
    end
  end

  describe "functions" do
    test "anonymous", %{rt: rt} do
      assert {:ok, 42} = eval_beam(rt, "(function(x) { return x * 2; })(21)")
    end

    test "closure", %{rt: rt} do
      assert {:ok, 7} = eval_beam(rt, "(function() { var x = 3; var y = 4; return x + y; })()")
    end
  end

  describe "control flow" do
    test "ternary", %{rt: rt} do
      assert {:ok, "yes"} = eval_beam(rt, "true ? 'yes' : 'no'")
      assert {:ok, "no"} = eval_beam(rt, "false ? 'yes' : 'no'")
    end

    test "comparison", %{rt: rt} do
      assert {:ok, true} = eval_beam(rt, "1 === 1")
      assert {:ok, false} = eval_beam(rt, "1 === 2")
      assert {:ok, true} = eval_beam(rt, "1 !== 2")
    end
  end

  describe "objects" do
    test "property access", %{rt: rt} do
      assert {:ok, "test"} = eval_beam(rt, ~s|({name: "test"}).name|)
    end
  end

  describe "arrays" do
    test "literal length", %{rt: rt} do
      assert {:ok, 3} = eval_beam(rt, "[1, 2, 3].length")
    end

    test "indexing", %{rt: rt} do
      assert {:ok, 20} = eval_beam(rt, "[10, 20, 30][1]")
    end
  end

  describe "built-ins" do
    test "Math.floor", %{rt: rt} do
      assert {:ok, 3} = eval_beam(rt, "Math.floor(3.7)")
    end
  end

  describe "loops" do
    test "while loop", %{rt: rt} do
      code = "(function() { var s = 0; var i = 0; while (i < 10) { s += i; i++; } return s; })()"
      assert {:ok, 45} = eval_beam(rt, code)
    end

    test "for loop", %{rt: rt} do
      code = "(function() { var s = 0; for (var i = 0; i < 10; i++) { s += i; } return s; })()"
      assert {:ok, 45} = eval_beam(rt, code)
    end
  end
end
