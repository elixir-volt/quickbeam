defmodule QuickBEAM.VM.Runtime.PromiseBuiltins do
  @moduledoc "JS `Promise` built-in: prototype `then`/`catch`/`finally` and static `resolve`/`reject`/`all`/`race`."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, Invocation, JSThrow}
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.PromiseState

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, _this ->
      case args do
        [executor | _] ->
          unless QuickBEAM.VM.Builtin.callable?(executor) do
            throw({:js_throw, Heap.make_error("Promise resolver is not a function", "TypeError")})
          end

          ref = make_ref()
          Heap.put_obj(ref, promise_pending_obj(ref))

          resolve_fn =
            resolving_function(fn args ->
              val = arg(args, 0, :undefined)
              unless already_settled?(ref), do: PromiseState.resolve_adopt(ref, val)
              :undefined
            end)

          reject_fn =
            resolving_function(fn args ->
              val = arg(args, 0, :undefined)
              unless already_settled?(ref), do: PromiseState.resolve(ref, :rejected, val)
              :undefined
            end)

          try do
            Invocation.invoke_with_receiver(executor, [resolve_fn, reject_fn], :undefined)
          catch
            {:js_throw, err} ->
              unless already_settled?(ref), do: PromiseState.resolve(ref, :rejected, err)
          end

          {:obj, ref}

        _ ->
          throw({:js_throw, Heap.make_error("Promise resolver is not a function", "TypeError")})
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
    |> maybe_put_promise_proto()
  end

  defp maybe_put_promise_proto(map) do
    case QuickBEAM.VM.Runtime.global_class_proto("Promise") do
      nil -> map
      proto -> Map.put(map, "__proto__", proto)
    end
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
    promise_resolve(this, arg(args, 0, :undefined))
  end

  static "reject" do
    promise_reject(this, arg(args, 0, :undefined))
  end

  static "all" do
    iterable = observe_constructor_resolve(this, arg(args, 0, :undefined))
    wrap_static_result(this, promise_all(iterable))
  end

  static "allSettled" do
    iterable = observe_constructor_resolve(this, arg(args, 0, :undefined))
    wrap_static_result(this, promise_all_settled(iterable))
  end

  static "allKeyed" do
    wrap_static_result(this, promise_all_keyed(arg(args, 0, :undefined)))
  end

  static "allSettledKeyed" do
    wrap_static_result(this, promise_all_settled_keyed(arg(args, 0, :undefined)))
  end

  static "any" do
    iterable = observe_constructor_resolve(this, arg(args, 0, :undefined))
    wrap_static_result(this, promise_any(iterable))
  end

  static "race" do
    iterable = observe_constructor_resolve(this, arg(args, 0, :undefined))
    wrap_static_result(this, promise_race(iterable))
  end

  static "try", length: 1 do
    promise_try(this, args)
  end

  static "withResolvers", length: 0 do
    with_resolvers(this)
  end

  defp wrap_static_result({:builtin, "Promise", _}, result), do: result

  defp wrap_static_result(constructor, result) do
    {promise, resolve, reject} = new_promise_capability(constructor)

    case result do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :resolved, promise_value() => value} ->
            Invocation.invoke(resolve, [value])

          %{promise_state() => :rejected, promise_value() => reason} ->
            Invocation.invoke(reject, [reason])

          %{promise_state() => :pending} ->
            :undefined

          _ ->
            Invocation.invoke(resolve, [result])
        end

      value ->
        Invocation.invoke(resolve, [value])
    end

    promise
  end

  defp observe_constructor_resolve(constructor, iterable) do
    values = Heap.to_list(iterable)
    resolve = QuickBEAM.VM.ObjectModel.Get.get(constructor, "resolve")

    unless QuickBEAM.VM.Builtin.callable?(resolve) do
      JSThrow.type_error!("Promise resolve is not callable")
    end

    Enum.each(values, fn value ->
      Invocation.invoke_with_receiver(resolve, [value], constructor)
    end)

    values
  end

  defp promise_resolve({:builtin, "Promise", _}, value), do: PromiseState.adopt(value)

  defp promise_resolve(constructor, value) do
    {promise, resolve, _reject} = new_promise_capability(constructor)
    Invocation.invoke(resolve, [value])
    promise
  end

  defp promise_reject({:builtin, "Promise", _}, reason), do: PromiseState.rejected(reason)

  defp promise_reject(constructor, reason) do
    {promise, _resolve, reject} = new_promise_capability(constructor)
    Invocation.invoke(reject, [reason])
    promise
  end

  defp unwrap_value({:obj, r} = obj) do
    case Heap.get_obj(r, %{}) do
      %{promise_state() => :resolved, promise_value() => val} -> val
      _ -> obj
    end
  end

  defp unwrap_value(val), do: val

  defp promise_inputs(arr), do: arr |> Heap.to_list() |> Enum.map(&PromiseState.adopt/1)

  defp promise_all(arr) do
    items = promise_inputs(arr)

    cond do
      rejection = first_rejection(items) ->
        {:rejected, reason} = rejection
        PromiseState.rejected(reason)

      pending_input?(items) ->
        PromiseState.pending()

      true ->
        results = Enum.map(items, &unwrap_value/1)
        PromiseState.resolved(Heap.wrap(results))
    end
  end

  defp first_rejection(items) do
    Enum.find_value(items, fn
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :rejected, promise_value() => reason} -> {:rejected, reason}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp pending_input?(items) do
    Enum.any?(items, fn
      {:obj, ref} -> match?(%{promise_state() => :pending}, Heap.get_obj(ref, %{}))
      _ -> false
    end)
  end

  defp promise_all_settled(arr) do
    items = promise_inputs(arr)

    if pending_input?(items) do
      PromiseState.pending()
    else
      results = Enum.map(items, &settled_result/1)
      PromiseState.resolved(Heap.wrap(results))
    end
  end

  defp promise_all_keyed(obj), do: keyed_promise_result(obj, &promise_all/1)
  defp promise_all_settled_keyed(obj), do: keyed_promise_result(obj, &promise_all_settled/1)

  defp keyed_promise_result(obj, resolver) do
    entries = keyed_entries(obj)
    values = Enum.map(entries, fn {_key, value} -> value end)

    case resolver.(values) do
      {:obj, ref} = promise ->
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :resolved, promise_value() => {:obj, values_ref}} ->
            values = Heap.get_obj(values_ref, [])

            result =
              entries
              |> Enum.zip(values)
              |> Enum.reduce(%{}, fn {{key, _}, value}, acc -> Map.put(acc, key, value) end)
              |> Heap.wrap()

            PromiseState.resolved(result)

          _ ->
            promise
        end

      other ->
        other
    end
  end

  defp keyed_entries({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        map
        |> Map.drop([
          promise_state(),
          promise_value(),
          "__proto__",
          :__internal_proto__,
          key_order()
        ])
        |> Enum.filter(fn {key, _} -> is_binary(key) end)
        |> Enum.sort_by(fn {key, _} -> key end)

      _ ->
        []
    end
  end

  defp keyed_entries(_), do: []

  defp settled_result(item) do
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
  end

  defp promise_any(arr) do
    items = promise_inputs(arr)

    case first_fulfillment(items) do
      {:fulfilled, value} ->
        PromiseState.resolved(value)

      :none ->
        if(pending_input?(items),
          do: PromiseState.pending(),
          else: PromiseState.rejected(aggregate_error(items))
        )
    end
  end

  defp first_fulfillment(items) do
    Enum.find_value(items, :none, fn
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :resolved, promise_value() => value} -> {:fulfilled, value}
          _ -> nil
        end

      value ->
        {:fulfilled, value}
    end)
  end

  defp aggregate_error(items) do
    reasons =
      items
      |> Enum.map(fn
        {:obj, ref} ->
          case Heap.get_obj(ref, %{}) do
            %{promise_state() => :rejected, promise_value() => reason} -> reason
            _ -> :undefined
          end

        _ ->
          :undefined
      end)
      |> Heap.wrap()

    {:obj, ref} = error = Heap.make_error("All promises were rejected", "AggregateError")
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), "errors", reasons))
    error
  end

  defp promise_try(constructor, args) do
    callback = arg(args, 0, :undefined)
    rest = Enum.drop(args, 1)
    {promise, resolve, reject} = new_promise_capability(constructor)

    try do
      value = Invocation.invoke(callback, rest)
      Invocation.invoke(resolve, [value])
    catch
      {:js_throw, reason} -> Invocation.invoke(reject, [reason])
    end

    promise
  end

  defp with_resolvers(constructor) do
    {promise, resolve, reject} = new_promise_capability(constructor)
    ref = make_ref()

    Heap.put_obj(ref, %{
      "__proto__" => Heap.get_object_prototype(),
      "promise" => promise,
      "resolve" => resolve,
      "reject" => reject,
      key_order() => ["reject", "resolve", "promise"]
    })

    for key <- ~w(promise resolve reject),
        do: Heap.put_prop_desc(ref, key, PropertyDescriptor.enumerable_data())

    {:obj, ref}
  end

  defp new_promise_capability(constructor) do
    captured = make_ref()
    Heap.put_obj(captured, %{})

    executor =
      capability_executor(fn args ->
        resolve = arg(args, 0, :undefined)
        reject = arg(args, 1, :undefined)

        unless QuickBEAM.VM.Builtin.callable?(resolve) and QuickBEAM.VM.Builtin.callable?(reject) do
          JSThrow.type_error!("Promise capability executor arguments must be callable")
        end

        Heap.put_obj(captured, %{"resolve" => resolve, "reject" => reject})
        :undefined
      end)

    promise = Invocation.construct_runtime(constructor, constructor, [executor])

    case Heap.get_obj(captured, %{}) do
      %{"resolve" => resolve, "reject" => reject} -> {promise, resolve, reject}
      _ -> JSThrow.type_error!("Promise constructor did not provide resolving functions")
    end
  end

  defp capability_executor(callback) when is_function(callback, 1) do
    fun = {:builtin, "__promiseCapabilityExecutor", fn args, _ -> callback.(args) end}
    Heap.put_ctor_static(fun, "length", 2)
    Heap.put_ctor_static(fun, "name", "")
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  defp resolving_function(callback) when is_function(callback, 1) do
    fun = {:builtin, "resolve", fn args, _ -> callback.(args) end}
    Heap.put_ctor_static(fun, "length", 1)
    Heap.put_ctor_static(fun, "name", "")
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  defp promise_race(arr) do
    items = promise_inputs(arr)

    if items == [] do
      PromiseState.pending()
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
