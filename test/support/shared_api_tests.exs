defmodule QuickBEAM.SharedAPITests do
  @moduledoc """
  Shared tests for the public QuickBEAM API.
  Included by both NIF and BEAM mode test modules.
  """

  defmacro __using__(opts) do
    mode = Keyword.fetch!(opts, :mode)

    quote do
      @mode unquote(mode)

      defp eval(rt, code), do: QuickBEAM.eval(rt, code, mode: @mode)
      defp call(rt, fn_name, args), do: QuickBEAM.call(rt, fn_name, args, mode: @mode)
      defp set_global(rt, name, val), do: QuickBEAM.set_global(rt, name, val, mode: @mode)
      defp get_global(rt, name), do: QuickBEAM.get_global(rt, name, mode: @mode)

      describe "basic types (#{@mode})" do
        test "numbers", %{rt: rt} do
          assert {:ok, 3} = eval(rt, "1 + 2")
          assert {:ok, 42} = eval(rt, "42")
          assert {:ok, 3.14} = eval(rt, "3.14")
        end

        test "booleans", %{rt: rt} do
          assert {:ok, true} = eval(rt, "true")
          assert {:ok, false} = eval(rt, "false")
        end

        test "null and undefined", %{rt: rt} do
          assert {:ok, nil} = eval(rt, "null")
          assert {:ok, nil} = eval(rt, "undefined")
        end

        test "strings", %{rt: rt} do
          assert {:ok, "hello"} = eval(rt, ~s["hello"])
          assert {:ok, ""} = eval(rt, ~s[""])
        end

        test "arrays", %{rt: rt} do
          assert {:ok, [1, 2, 3]} = eval(rt, "[1, 2, 3]")
          assert {:ok, []} = eval(rt, "[]")
        end

        test "objects", %{rt: rt} do
          assert {:ok, %{"a" => 1}} = eval(rt, "({a: 1})")
        end
      end

      describe "functions (#{@mode})" do
        test "define and call", %{rt: rt} do
          eval(rt, "function shared_add(a, b) { return a + b; }")
          assert {:ok, 42} = call(rt, "shared_add", [10, 32])
        end

        test "arrow functions", %{rt: rt} do
          assert {:ok, 42} = eval(rt, "((x) => x * 2)(21)")
        end
      end

      describe "errors (#{@mode})" do
        test "thrown errors", %{rt: rt} do
          assert {:error, _} = eval(rt, ~s[throw new Error("boom")])
        end

        test "reference errors", %{rt: rt} do
          assert {:error, _} = eval(rt, "nonExistent")
        end

        test "syntax errors", %{rt: rt} do
          assert {:error, _} = eval(rt, "function(")
        end

        test "TypeError", %{rt: rt} do
          assert {:error, _} = eval(rt, "null.foo")
        end
      end

      describe "promises (#{@mode})" do
        test "Promise.resolve", %{rt: rt} do
          assert {:ok, 42} = eval(rt, "(async () => await Promise.resolve(42))()")
        end

        test "async/await", %{rt: rt} do
          assert {:ok, 99} = eval(rt, "(async () => await Promise.resolve(99))()")
        end

        test "chained promises", %{rt: rt} do
          assert {:ok, 6} =
                   eval(
                     rt,
                     "(async () => await Promise.resolve(2).then(x => x * 3))()"
                   )
        end
      end

      describe "globals (#{@mode})" do
        test "set and get", %{rt: rt} do
          set_global(rt, "__shared_test_val", 42)
          assert {:ok, 42} = get_global(rt, "__shared_test_val")
        end

        test "get undefined", %{rt: rt} do
          result = get_global(rt, "__nonexistent_shared")
          assert {:ok, val} = result
          assert val in [nil, :undefined]
        end

        test "persist across evals", %{rt: rt} do
          eval(rt, "var __shared_counter = 10")
          assert {:ok, 10} = eval(rt, "(__shared_counter)")
        end
      end

      describe "interop (#{@mode})" do
        test "call JS function from Elixir", %{rt: rt} do
          eval(rt, "function shared_mul(a, b) { return a * b }")
          assert {:ok, 12} = call(rt, "shared_mul", [3, 4])
        end
      end
    end
  end
end
