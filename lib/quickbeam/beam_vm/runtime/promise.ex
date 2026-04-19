defmodule QuickBEAM.BeamVM.Runtime.Promise do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.Heap

  alias QuickBEAM.BeamVM.Interpreter.Promise

  def constructor do
    fn _args, _this -> Heap.wrap(%{}) end
  end

  static "resolve" do
    case args do
      [val | _] -> Promise.resolved(val)
      [] -> Promise.resolved(:undefined)
    end
  end

  static "reject" do
    Promise.rejected(List.first(args, :undefined))
  end

  static "all" do
    promise_all(hd(args))
  end

  static "allSettled" do
    promise_all_settled(hd(args))
  end

  static "any" do
    promise_any(hd(args))
  end

  static "race" do
    promise_race(hd(args))
  end

  defp unwrap_value({:obj, r} = obj) do
    case Heap.get_obj(r, %{}) do
      %{promise_state() => :resolved, promise_value() => val} -> val
      _ -> obj
    end
  end

  defp unwrap_value(val), do: val

  defp promise_all(arr) do
    items = Heap.to_list(arr)

    results = Enum.map(items, &unwrap_value/1)

    Promise.resolved(Heap.wrap(results))
  end

  defp promise_all_settled(arr) do
    items = Heap.to_list(arr)

    results =
      Enum.map(items, fn item ->
        {status, val} =
          case item do
            {:obj, r} ->
              case Heap.get_obj(r, %{}) do
                %{promise_state() => :resolved, promise_value() => v} -> {"fulfilled", v}
                %{promise_state() => :rejected, promise_value() => v} -> {"rejected", v}
                _ -> {"fulfilled", item}
              end

            _ ->
              {"fulfilled", item}
          end

        if status == "fulfilled",
          do: Heap.wrap(%{"status" => status, "value" => val}),
          else: Heap.wrap(%{"status" => status, "reason" => val})
      end)

    Promise.resolved(Heap.wrap(results))
  end

  defp promise_any(arr) do
    items = Heap.to_list(arr)

    result =
      Enum.find_value(items, fn
        {:obj, r} ->
          case Heap.get_obj(r, %{}) do
            %{promise_state() => :resolved, promise_value() => v} -> v
            _ -> nil
          end

        val ->
          val
      end)

    Promise.resolved(result || :undefined)
  end

  defp promise_race(arr) do
    items = Heap.to_list(arr)

    case items do
      [first | _] -> Promise.resolved(unwrap_value(first))
      [] -> Promise.resolved(:undefined)
    end
  end
end
