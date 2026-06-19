defmodule QuickBEAM.VM.RealmTest do
  use ExUnit.Case, async: true

  setup do
    assert {:ok, runtime} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(runtime)
      catch
        :exit, _ -> :ok
      end
    end)

    %{runtime: runtime}
  end

  test "$262.createRealm allocates distinct error intrinsics", %{runtime: runtime} do
    assert {:ok, "true|true"} =
             eval(
               runtime,
               ~S<let g=$262.createRealm().global; [g.TypeError !== TypeError, g.TypeError.prototype !== TypeError.prototype].join("|")>
             )
  end

  test "realm Function calls default to their own global object", %{runtime: runtime} do
    assert {:ok, true} =
             eval(
               runtime,
               ~S<let g=$262.createRealm().global; let F = g.Function('return this'); F() === g>
             )
  end

  test "cross-realm constructor results use the target realm prototype", %{runtime: runtime} do
    assert {:ok, true} =
             eval(
               runtime,
               ~S<let g=$262.createRealm().global; Object.getPrototypeOf(new g.Number(1)) === g.Number.prototype>
             )
  end

  test "dynamic functions use new target realm fallback prototype", %{runtime: runtime} do
    assert {:ok, true} =
             eval(
               runtime,
               ~S"""
               let g = $262.createRealm().global;
               let C = new g.Function();
               C.prototype = null;
               Object.getPrototypeOf(Reflect.construct(Function, [], C)) === g.Function.prototype
               """
             )
  end

  test "cross-realm Boolean construction uses new target realm prototype", %{runtime: runtime} do
    assert {:ok, true} =
             eval(
               runtime,
               ~S"""
               let g = $262.createRealm().global;
               let C = new g.Function();
               C.prototype = null;
               Object.getPrototypeOf(Reflect.construct(Boolean, [], C)) === g.Boolean.prototype
               """
             )
  end

  test "realm Function apply throws realm TypeError", %{runtime: runtime} do
    assert {:ok, "true|true"} =
             eval(
               runtime,
               ~S"""
               let g = $262.createRealm().global;
               let fn = new g.Function();
               let first, second;
               try { fn.apply(null, false); } catch (e) { first = e.constructor === g.TypeError; }
               try { g.Function.prototype.apply.call(undefined, {}, []); } catch (e) { second = e.constructor === g.TypeError; }
               first + "|" + second
               """
             )
  end

  defp eval(runtime, source), do: QuickBEAM.eval(runtime, source, mode: :beam)
end
