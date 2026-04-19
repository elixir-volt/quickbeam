defmodule QuickBEAM.BeamVM.Runtime.Promise do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Heap

  @promise_state "__promise_state__"
  @promise_value "__promise_value__"

  alias QuickBEAM.BeamVM.Interpreter.Promise, as: PromiseInterp

  def constructor do
    fn _args, _this -> Heap.wrap(%{}) end
  end

  def statics do
    build_methods do
      method "resolve" do
        case args do
          [val | _] -> PromiseInterp.resolved(val)
          [] -> PromiseInterp.resolved(:undefined)
        end
      end

      method "reject" do
        PromiseInterp.rejected(List.first(args, :undefined))
      end

      method "all" do
        promise_all(hd(args))
      end

      method "allSettled" do
        promise_all_settled(hd(args))
      end

      method "any" do
        promise_any(hd(args))
      end

      method "race" do
        promise_race(hd(args))
      end
    end
  end

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
