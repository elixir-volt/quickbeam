defmodule QuickBEAM.VM.Runtime.PromiseBuiltins do
  @moduledoc "JS `Promise` built-in: prototype `then`/`catch`/`finally` and static `resolve`/`reject`/`all`/`race`."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.PromiseState

  def constructor do
    fn args, _this ->
      case args do
        [executor | _] when not is_nil(executor) and executor != :undefined ->
          ref = make_ref()
          Heap.put_obj(ref, promise_pending_obj(ref))

          resolve_fn =
            {:builtin, "resolve",
             fn args, _ ->
               val = List.first(args, :undefined)
               unless already_settled?(ref), do: PromiseState.resolve(ref, :resolved, val)
               :undefined
             end}

          reject_fn =
            {:builtin, "reject",
             fn args, _ ->
               val = List.first(args, :undefined)
               unless already_settled?(ref), do: PromiseState.resolve(ref, :rejected, val)
               :undefined
             end}

          try do
            QuickBEAM.VM.Interpreter.invoke_callback(executor, [resolve_fn, reject_fn])
          catch
            {:js_throw, err} ->
              unless already_settled?(ref), do: PromiseState.resolve(ref, :rejected, err)
          end

          {:obj, ref}

        _ ->
          Heap.wrap(%{})
      end
    end
  end

  defp promise_pending_obj(ref) do
    %{
      promise_state() => :pending,
      promise_value() => nil,
      "then" => {:builtin, "then", fn args, _this -> PromiseState.promise_then(args, {:obj, ref}) end},
      "catch" => {:builtin, "catch", fn args, _this -> PromiseState.promise_catch(args, {:obj, ref}) end}
    }
  end

  defp already_settled?(ref) do
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected] -> true
      _ -> false
    end
  end

  def prototype do
    build_object do
      val("then", {:builtin, "then", &PromiseState.promise_then/2})
      val("catch", {:builtin, "catch", &PromiseState.promise_catch/2})
      val("finally", {:builtin, "finally", &PromiseState.promise_finally/2})
    end
  end

  static "resolve" do
    case args do
      [val | _] -> PromiseState.resolved(val)
      [] -> PromiseState.resolved(:undefined)
    end
  end

  static "reject" do
    PromiseState.rejected(List.first(args, :undefined))
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

    PromiseState.resolved(Heap.wrap(results))
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

    PromiseState.resolved(Heap.wrap(results))
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

    PromiseState.resolved(result || :undefined)
  end

  defp promise_race(arr) do
    items = Heap.to_list(arr)

    case items do
      [first | _] -> PromiseState.resolved(unwrap_value(first))
      [] -> PromiseState.resolved(:undefined)
    end
  end
end
