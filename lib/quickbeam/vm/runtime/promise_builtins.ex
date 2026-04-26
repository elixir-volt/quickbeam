defmodule QuickBEAM.VM.Runtime.PromiseBuiltins do
  @moduledoc "JS `Promise` built-in: prototype `then`/`catch`/`finally` and static `resolve`/`reject`/`all`/`race`."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.PromiseState

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, _this ->
      case args do
        [executor | _] when not is_nil(executor) and executor != :undefined ->
          ref = make_ref()
          Heap.put_obj(ref, promise_pending_obj(ref))

          resolve_fn =
            {:builtin, "resolve",
             fn args, _ ->
               val = arg(args, 0, :undefined)
               unless already_settled?(ref), do: PromiseState.resolve(ref, :resolved, val)
               :undefined
             end}

          reject_fn =
            {:builtin, "reject",
             fn args, _ ->
               val = arg(args, 0, :undefined)
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
      "then" =>
        {:builtin, "then", fn args, _this -> PromiseState.promise_then(args, {:obj, ref}) end},
      "catch" =>
        {:builtin, "catch", fn args, _this -> PromiseState.promise_catch(args, {:obj, ref}) end}
    }
  end

  defp already_settled?(ref) do
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected] -> true
      _ -> false
    end
  end

  @doc "Builds the JavaScript prototype object for this runtime builtin."
  def prototype do
    object do
      prop("then", {:builtin, "then", &PromiseState.promise_then/2})
      prop("catch", {:builtin, "catch", &PromiseState.promise_catch/2})
      prop("finally", {:builtin, "finally", &PromiseState.promise_finally/2})
    end
  end

  static "resolve" do
    case args do
      [val | _] -> PromiseState.resolved(val)
      [] -> PromiseState.resolved(:undefined)
    end
  end

  static "reject" do
    args |> arg(0, :undefined) |> PromiseState.rejected()
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

    if items == [] do
      PromiseState.resolved(:undefined)
    else
      # Check if any already resolved
      already =
        Enum.find_value(items, fn
          {:obj, r} ->
            case Heap.get_obj(r, %{}) do
              %{promise_state() => :resolved, promise_value() => v} -> {:ok, v}
              %{promise_state() => :rejected, promise_value() => v} -> {:err, v}
              _ -> nil
            end

          val ->
            {:ok, val}
        end)

      case already do
        {:ok, v} ->
          PromiseState.resolved(v)

        {:err, v} ->
          PromiseState.rejected(v)

        nil ->
          race_ref = make_ref()
          Heap.put_obj(race_ref, %{promise_state() => :pending, promise_value() => nil})
          race_promise = {:obj, race_ref}

          Enum.each(items, fn item ->
            case item do
              {:obj, _} ->
                on_fulfilled =
                  {:builtin, "__race_fulfilled",
                   fn args, _ ->
                     val = arg(args, 0, :undefined)

                     case Heap.get_obj(race_ref, %{}) do
                       %{promise_state() => :pending} ->
                         PromiseState.resolve(race_ref, :resolved, val)

                       _ ->
                         :ok
                     end

                     val
                   end}

                on_rejected =
                  {:builtin, "__race_rejected",
                   fn args, _ ->
                     reason = arg(args, 0, :undefined)

                     case Heap.get_obj(race_ref, %{}) do
                       %{promise_state() => :pending} ->
                         PromiseState.resolve(race_ref, :rejected, reason)

                       _ ->
                         :ok
                     end

                     throw({:js_throw, reason})
                   end}

                PromiseState.promise_then([on_fulfilled, on_rejected], item)

              _ ->
                case Heap.get_obj(race_ref, %{}) do
                  %{promise_state() => :pending} ->
                    PromiseState.resolve(race_ref, :resolved, item)

                  _ ->
                    :ok
                end
            end
          end)

          race_promise
      end
    end
  end
end
