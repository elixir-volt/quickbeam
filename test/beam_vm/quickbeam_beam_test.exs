defmodule QuickBEAM.BeamModeAPITest do
  @moduledoc """
  Runs the core QuickBEAM API tests using mode: :beam.
  Same tests as quickbeam_test.exs, adapted for BEAM VM backend.
  NIF-only features (timers, bytecode, disasm, reset, Beam.call) excluded.
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, rt} = QuickBEAM.start(mode: :beam)
    %{rt: rt}
  end

  describe "basic types" do
    test "numbers", %{rt: rt} do
      assert {:ok, 3} = QuickBEAM.eval(rt, "1 + 2")
      assert {:ok, 42} = QuickBEAM.eval(rt, "42")
      assert {:ok, 3.14} = QuickBEAM.eval(rt, "3.14")
    end

    test "booleans", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "true")
      assert {:ok, false} = QuickBEAM.eval(rt, "false")
    end

    test "null and undefined", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "null")
      assert {:ok, nil} = QuickBEAM.eval(rt, "undefined")
    end

    test "strings", %{rt: rt} do
      assert {:ok, "hello"} = QuickBEAM.eval(rt, ~s["hello"])
      assert {:ok, ""} = QuickBEAM.eval(rt, ~s[""])
      assert {:ok, "hello world"} = QuickBEAM.eval(rt, ~s["hello world"])
    end

    test "arrays", %{rt: rt} do
      assert {:ok, [1, 2, 3]} = QuickBEAM.eval(rt, "[1, 2, 3]")
      assert {:ok, []} = QuickBEAM.eval(rt, "[]")
      assert {:ok, ["a", 1, true]} = QuickBEAM.eval(rt, ~s|["a", 1, true]|)
    end

    test "objects", %{rt: rt} do
      assert {:ok, %{"a" => 1}} = QuickBEAM.eval(rt, "({a: 1})")

      assert {:ok, %{"name" => "QuickBEAM", "version" => 1}} =
               QuickBEAM.eval(rt, ~s[({name: "QuickBEAM", version: 1})])
    end
  end

  describe "functions" do
    test "define and call", %{rt: rt} do
      QuickBEAM.eval(rt, "function beam_add(a, b) { return a + b; }")
      assert {:ok, 42} = QuickBEAM.call(rt, "beam_add", [10, 32])
    end

    test "arrow functions", %{rt: rt} do
      assert {:ok, 84} = QuickBEAM.eval(rt, "((x) => x * 2)(42)")
    end
  end

  describe "errors" do
    test "thrown errors", %{rt: rt} do
      assert {:error, err} = QuickBEAM.eval(rt, ~s[throw new Error("boom")])
      assert is_map(err)
      assert err["message"] == "boom"
    end

    test "reference errors", %{rt: rt} do
      assert {:error, err} = QuickBEAM.eval(rt, "undeclaredVar")
      assert is_map(err)
      assert err["name"] == "ReferenceError"
    end

    test "syntax errors", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "if (")
    end

    test "error has stack trace", %{rt: rt} do
      assert {:error, err} = QuickBEAM.eval(rt, ~s[throw new Error("test")])
      assert is_map(err)
      assert is_binary(err["stack"])
    end

    test "thrown non-Error values", %{rt: rt} do
      assert {:error, 42} = QuickBEAM.eval(rt, "throw 42")
    end

    test "TypeError", %{rt: rt} do
      assert {:error, err} = QuickBEAM.eval(rt, "null.foo")
      assert is_map(err)
      assert err["name"] == "TypeError"
    end
  end

  describe "promises" do
    test "Promise.resolve", %{rt: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, "(async () => await Promise.resolve(42))()")
    end

    test "async/await", %{rt: rt} do
      assert {:ok, 99} = QuickBEAM.eval(rt, "(async () => await Promise.resolve(99))()")
    end

    test "chained promises", %{rt: rt} do
      assert {:ok, 6} =
               QuickBEAM.eval(rt, "(async () => await Promise.resolve(2).then(x => x * 3))()")
    end
  end

  describe "globals" do
    test "set and get", %{rt: rt} do
      QuickBEAM.set_global(rt, "__beam_test_val", 42)
      assert {:ok, 42} = QuickBEAM.get_global(rt, "__beam_test_val")
    end

    test "persist across evals", %{rt: rt} do
      QuickBEAM.eval(rt, "var __beam_counter = 10")
      assert {:ok, 10} = QuickBEAM.eval(rt, "(__beam_counter)")
    end

    test "get undefined", %{rt: rt} do
      assert {:ok, val} = QuickBEAM.get_global(rt, "__nonexistent_beam")
      assert val in [nil, :undefined]
    end
  end

  describe "interop" do
    test "call JS function from Elixir", %{rt: rt} do
      QuickBEAM.eval(rt, "function beam_mul(a, b) { return a * b }")
      assert {:ok, 12} = QuickBEAM.call(rt, "beam_mul", [3, 4])
    end

    test "modules", %{rt: rt} do
      QuickBEAM.load_module(rt, "__beam_math", "exports.sq = function(x) { return x * x }")

      assert {:ok, 49} =
               QuickBEAM.eval(rt, "(function(){ return require('__beam_math').sq(7) })()")
    end
  end
end
