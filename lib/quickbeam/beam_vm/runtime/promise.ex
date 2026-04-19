defmodule QuickBEAM.BeamVM.Runtime.Promise do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  @promise_state "__promise_state__"
  @promise_value "__promise_value__"

  alias QuickBEAM.BeamVM.Interpreter.Promise, as: PromiseInterp

  def constructor do
    fn _args, _this -> Heap.wrap(%{}) end
  end

  def statics do
    %{
      "resolve" => {:builtin, "resolve", &builtin_resolve/2},
      "reject" => {:builtin, "reject", &builtin_reject/2},
      "all" => {:builtin, "all", &builtin_all/2},
      "allSettled" => {:builtin, "allSettled", &builtin_all_settled/2},
      "any" => {:builtin, "any", &builtin_any/2},
      "race" => {:builtin, "race", &builtin_race/2}
    }
  end

  defp builtin_resolve([val | _], _this), do: PromiseInterp.resolved(val)
  defp builtin_resolve([], _this), do: PromiseInterp.resolved(:undefined)

  defp builtin_reject([val | _], _this), do: PromiseInterp.rejected(val)

  defp builtin_all([arr | _], _this), do: promise_all(arr)

  defp builtin_all_settled([arr | _], _this), do: promise_all_settled(arr)

  defp builtin_any([arr | _], _this), do: promise_any(arr)

  defp builtin_race([arr | _], _this), do: promise_race(arr)

  defp promise_all(arr) do
    items = Heap.to_list(arr)

    results =
      Enum.map(items, fn item ->
        case item do
          {:obj, r} ->
            case Heap.get_obj(r, %{}) do
              %{@promise_state => :resolved, @promise_value => val} -> val
              _ -> item
            end

          _ ->
            item
        end
      end)

    PromiseInterp.resolved(Heap.wrap(results))
  end

  defp promise_all_settled(arr) do
    items = Heap.to_list(arr)

    results =
      Enum.map(items, fn item ->
        {status, val} =
          case item do
            {:obj, r} ->
              case Heap.get_obj(r, %{}) do
                %{@promise_state => :resolved, @promise_value => v} -> {"fulfilled", v}
                %{@promise_state => :rejected, @promise_value => v} -> {"rejected", v}
                _ -> {"fulfilled", item}
              end

            _ ->
              {"fulfilled", item}
          end

        if status == "fulfilled",
          do: Heap.wrap(%{"status" => status, "value" => val}),
          else: Heap.wrap(%{"status" => status, "reason" => val})
      end)

    PromiseInterp.resolved(Heap.wrap(results))
  end

  defp promise_any(arr) do
    items = Heap.to_list(arr)

    result =
      Enum.find_value(items, fn item ->
        case item do
          {:obj, r} ->
            case Heap.get_obj(r, %{}) do
              %{@promise_state => :resolved, @promise_value => v} -> v
              _ -> nil
            end

          _ ->
            item
        end
      end)

    PromiseInterp.resolved(result || :undefined)
  end

  defp promise_race(arr) do
    items = Heap.to_list(arr)

    case items do
      [first | _] ->
        val =
          case first do
            {:obj, r} ->
              case Heap.get_obj(r, %{}) do
                %{@promise_state => :resolved, @promise_value => v} -> v
                _ -> first
              end

            _ ->
              first
          end

        PromiseInterp.resolved(val)

      [] ->
        PromiseInterp.resolved(:undefined)
    end
  end
end
