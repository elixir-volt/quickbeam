defmodule QuickBEAM.VM.Runtime.Promise do
  @moduledoc "JS `Promise` built-in: prototype `then`/`catch`/`finally` and static `resolve`/`reject`/`all`/`race`."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, Invocation, JSThrow}
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime.{ConstructorRegistry, InstallerHelpers}
  alias QuickBEAM.VM.Semantics.Iterators
  alias QuickBEAM.VM.Promise

  builtin_definition("Promise",
    constructor: constructor(),
    length: 1,
    phase: :fundamental,
    after_install: &__MODULE__.install_builtin/2
  )

  def install_builtin(ctor, opts \\ []) do
    object_proto = Keyword.get(opts, :object_proto, Heap.get_object_prototype())

    ConstructorRegistry.put_prototype(ctor, prototype(object_proto))
    Heap.put_ctor_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
    InstallerHelpers.install_species(ctor)

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_object_parent(proto_ref, object_proto)

      for name <- ~w(then catch finally) do
        Heap.put_prop_desc(proto_ref, name, PropertyDescriptor.method())
      end

      InstallerHelpers.install_to_string_tag(proto_ref, "Promise")
      InstallerHelpers.install_constructor_link(proto_ref, ctor)
    end)
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, this ->
      case args do
        [executor | _] ->
          unless QuickBEAM.VM.Builtin.callable?(executor) do
            throw({:js_throw, Heap.make_error("Promise resolver is not a function", "TypeError")})
          end

          ref = promise_result_ref(this)
          install_promise_slots(ref)

          resolve_fn =
            resolving_function(fn args ->
              val = arg(args, 0, :undefined)
              unless already_settled?(ref), do: Promise.resolve_adopt(ref, val)
              :undefined
            end)

          reject_fn =
            resolving_function(fn args ->
              val = arg(args, 0, :undefined)
              unless already_settled?(ref), do: Promise.resolve(ref, :rejected, val)
              :undefined
            end)

          try do
            Invocation.invoke_with_receiver(executor, [resolve_fn, reject_fn], :undefined)
          catch
            {:js_throw, err} ->
              unless already_settled?(ref), do: Promise.resolve(ref, :rejected, err)
          end

          {:obj, ref}

        _ ->
          throw({:js_throw, Heap.make_error("Promise resolver is not a function", "TypeError")})
      end
    end
  end

  defp promise_result_ref({:obj, ref}), do: ref
  defp promise_result_ref(_this), do: make_ref()

  defp install_promise_slots(ref) do
    existing = Heap.get_obj(ref, %{})
    pending = promise_pending_obj(ref)
    proto = Map.get(existing, "__proto__", Map.get(pending, "__proto__"))

    ref
    |> Heap.put_obj(existing |> Map.merge(pending) |> Map.put("__proto__", proto))
  end

  defp promise_pending_obj(_ref) do
    %{
      promise_state() => :pending,
      promise_value() => nil
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
  def prototype(object_proto \\ Heap.get_object_prototype()) do
    base = %{
      "then" => {:builtin, "then", &Promise.promise_then/2},
      "catch" => {:builtin, "catch", &Promise.promise_catch/2},
      "finally" => {:builtin, "finally", &Promise.promise_finally/2}
    }

    base =
      case object_proto do
        {:obj, _} -> Map.put(base, "__proto__", object_proto)
        _ -> base
      end

    Heap.wrap(base)
  end

  static "resolve" do
    promise_resolve(this, arg(args, 0, :undefined))
  end

  static "reject" do
    promise_reject(this, arg(args, 0, :undefined))
  end

  static "all" do
    if default_promise_constructor?(this) do
      case combinator_inputs(this, arg(args, 0, :undefined)) do
        {:ok, items} -> wrap_static_result(this, promise_all_items(items))
        {:abrupt, reason} -> wrap_static_result(this, Promise.rejected(reason))
      end
    else
      perform_promise_all(this, arg(args, 0, :undefined))
    end
  end

  static "allSettled" do
    if default_promise_constructor?(this) do
      case combinator_inputs(this, arg(args, 0, :undefined)) do
        {:ok, items} -> wrap_static_result(this, promise_all_settled_items(items))
        {:abrupt, reason} -> wrap_static_result(this, Promise.rejected(reason))
      end
    else
      perform_promise_all_settled(this, arg(args, 0, :undefined))
    end
  end

  static "allKeyed" do
    wrap_static_result(this, promise_all_keyed(arg(args, 0, :undefined)))
  end

  static "allSettledKeyed" do
    wrap_static_result(this, promise_all_settled_keyed(arg(args, 0, :undefined)))
  end

  static "any" do
    if default_promise_constructor?(this) do
      case combinator_inputs(this, arg(args, 0, :undefined)) do
        {:ok, items} -> wrap_static_result(this, promise_any_items(items))
        {:abrupt, reason} -> wrap_static_result(this, Promise.rejected(reason))
      end
    else
      perform_promise_any(this, arg(args, 0, :undefined))
    end
  end

  static "race" do
    if default_promise_constructor?(this) do
      case combinator_inputs(this, arg(args, 0, :undefined)) do
        {:ok, items} -> wrap_static_result(this, promise_race_items(items))
        {:abrupt, reason} -> wrap_static_result(this, Promise.rejected(reason))
      end
    else
      perform_promise_race(this, arg(args, 0, :undefined))
    end
  end

  static "try", length: 1 do
    promise_try(this, args)
  end

  static "withResolvers", length: 0 do
    with_resolvers(this)
  end

  defp default_promise_constructor?({:builtin, "Promise", _}), do: true
  defp default_promise_constructor?(_), do: false

  defp wrap_static_result({:builtin, "Promise", _}, result), do: result

  defp wrap_static_result(constructor, result) do
    {promise, resolve, reject} = new_promise_capability(constructor)

    case result do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :resolved, promise_value() => value} ->
            invoke_capability_resolve(resolve, reject, value)

          %{promise_state() => :rejected, promise_value() => reason} ->
            Invocation.invoke(reject, [reason])

          %{promise_state() => :pending} ->
            Promise.promise_then([resolve, reject], result)

          _ ->
            invoke_capability_resolve(resolve, reject, result)
        end

      value ->
        invoke_capability_resolve(resolve, reject, value)
    end

    promise
  end

  defp invoke_capability_resolve(resolve, reject, value) do
    try do
      Invocation.invoke(resolve, [value])
    catch
      {:js_throw, reason} -> Invocation.invoke(reject, [reason])
    end
  end

  defp combinator_inputs(constructor, iterable) do
    try do
      {iter, next_fn} = Iterators.for_of_start(iterable)
      resolve = QuickBEAM.VM.ObjectModel.Get.get(constructor, "resolve")

      unless QuickBEAM.VM.Builtin.callable?(resolve) do
        JSThrow.type_error!("Promise resolve is not callable")
      end

      collect_combinator_inputs(iter, next_fn, resolve, constructor, [])
    catch
      {:js_throw, reason} -> {:abrupt, reason}
    end
  end

  defp collect_combinator_inputs(iter, next_fn, resolve, constructor, acc) do
    case promise_for_of_next(next_fn, iter) do
      {true, _, _} ->
        {:ok, Enum.reverse(acc)}

      {false, value, next_iter} ->
        try do
          next_promise = Invocation.invoke_with_receiver(resolve, [value], constructor)
          adopted = Promise.adopt(next_promise)
          observed = observe_input_then(adopted)
          collect_combinator_inputs(next_iter, next_fn, resolve, constructor, [observed | acc])
        catch
          {:js_throw, reason} ->
            close_iterator_preserving_throw(next_iter)
            {:abrupt, reason}
        end
    end
  end

  defp promise_for_of_next(_next_fn, :undefined), do: {true, :undefined, :undefined}

  defp promise_for_of_next(_next_fn, {:list_iter, [head | tail]}),
    do: {false, head, {:list_iter, tail}}

  defp promise_for_of_next(_next_fn, {:list_iter, []}), do: {true, :undefined, :undefined}

  defp promise_for_of_next(_next_fn, {:array_iter, obj, index}) do
    length = QuickBEAM.VM.Runtime.to_int(QuickBEAM.VM.ObjectModel.Get.get(obj, "length"))

    if index >= length do
      {true, :undefined, :undefined}
    else
      {false, QuickBEAM.VM.ObjectModel.Get.get(obj, Integer.to_string(index)),
       {:array_iter, obj, index + 1}}
    end
  end

  defp promise_for_of_next(next_fn, iter_obj) do
    result = Invocation.invoke_with_receiver(next_fn, [], iter_obj)

    unless QuickBEAM.VM.Semantics.Iterators.iterator_result_object?(result),
      do: JSThrow.type_error!("iterator result is not an object")

    if QuickBEAM.VM.Runtime.truthy?(QuickBEAM.VM.ObjectModel.Get.get(result, "done")) do
      {true, :undefined, :undefined}
    else
      {false, QuickBEAM.VM.ObjectModel.Get.get(result, "value"), iter_obj}
    end
  end

  defp close_iterator_preserving_throw(iter) do
    try do
      Iterators.iterator_close(iter)
    catch
      {:js_throw, _reason} -> :ok
    end
  end

  defp perform_promise_all(constructor, iterable) do
    {promise, resolve, reject} = new_promise_capability(constructor)

    try do
      {iter, next_fn} = Iterators.for_of_start(iterable)
      promise_resolve_fn = QuickBEAM.VM.ObjectModel.Get.get(constructor, "resolve")

      unless QuickBEAM.VM.Builtin.callable?(promise_resolve_fn) do
        JSThrow.type_error!("Promise resolve is not callable")
      end

      state_ref = make_ref()
      Heap.put_obj(state_ref, %{"remaining" => 1, "values" => []})
      perform_all_loop(iter, next_fn, constructor, promise_resolve_fn, state_ref, resolve, reject)
      promise
    catch
      {:js_throw, reason} ->
        Invocation.invoke(reject, [reason])
        promise
    end
  end

  defp perform_all_loop(
         iter,
         next_fn,
         constructor,
         promise_resolve_fn,
         state_ref,
         resolve,
         reject
       ) do
    case promise_for_of_next(next_fn, iter) do
      {true, _, _} ->
        state = Heap.get_obj(state_ref, %{})
        remaining = state["remaining"] - 1
        Heap.put_obj(state_ref, %{state | "remaining" => remaining})

        if remaining == 0 do
          invoke_capability_resolve(resolve, reject, Heap.wrap(state["values"]))
        end

      {false, value, next_iter} ->
        try do
          next_promise = Invocation.invoke_with_receiver(promise_resolve_fn, [value], constructor)
          index = append_pending_all_value(state_ref)
          then = QuickBEAM.VM.ObjectModel.Get.get(next_promise, "then")

          unless QuickBEAM.VM.Builtin.callable?(then) do
            JSThrow.type_error!("Promise then is not callable")
          end

          Invocation.invoke_with_receiver(
            then,
            [
              once_function(fn settled ->
                fulfill_all_element(state_ref, resolve, reject, index, settled)
              end),
              reject
            ],
            next_promise
          )

          perform_all_loop(
            next_iter,
            next_fn,
            constructor,
            promise_resolve_fn,
            state_ref,
            resolve,
            reject
          )
        catch
          {:js_throw, reason} ->
            close_iterator_preserving_throw(next_iter)
            throw({:js_throw, reason})
        end
    end
  end

  defp append_pending_all_value(state_ref) do
    state = Heap.get_obj(state_ref, %{})
    values = state["values"] ++ [:undefined]
    index = length(values) - 1
    Heap.put_obj(state_ref, %{state | "values" => values, "remaining" => state["remaining"] + 1})
    index
  end

  defp fulfill_all_element(state_ref, resolve, reject, index, value) do
    state = Heap.get_obj(state_ref, %{})
    values = List.replace_at(state["values"], index, value)
    remaining = state["remaining"] - 1
    Heap.put_obj(state_ref, %{state | "values" => values, "remaining" => remaining})

    if remaining == 0 do
      invoke_capability_resolve(resolve, reject, Heap.wrap(values))
    end

    :undefined
  end

  defp perform_promise_all_settled(constructor, iterable) do
    {promise, resolve, reject} = new_promise_capability(constructor)

    try do
      {iter, next_fn} = Iterators.for_of_start(iterable)
      promise_resolve_fn = QuickBEAM.VM.ObjectModel.Get.get(constructor, "resolve")

      unless QuickBEAM.VM.Builtin.callable?(promise_resolve_fn) do
        JSThrow.type_error!("Promise resolve is not callable")
      end

      state_ref = make_ref()
      Heap.put_obj(state_ref, %{"remaining" => 1, "values" => []})

      perform_all_settled_loop(
        iter,
        next_fn,
        constructor,
        promise_resolve_fn,
        state_ref,
        resolve,
        reject
      )

      promise
    catch
      {:js_throw, reason} ->
        Invocation.invoke(reject, [reason])
        promise
    end
  end

  defp perform_all_settled_loop(
         iter,
         next_fn,
         constructor,
         promise_resolve_fn,
         state_ref,
         resolve,
         reject
       ) do
    case promise_for_of_next(next_fn, iter) do
      {true, _, _} ->
        state = Heap.get_obj(state_ref, %{})
        remaining = state["remaining"] - 1
        Heap.put_obj(state_ref, %{state | "remaining" => remaining})

        if remaining == 0 do
          invoke_capability_resolve(resolve, reject, Heap.wrap(state["values"]))
        end

      {false, value, next_iter} ->
        try do
          next_promise = Invocation.invoke_with_receiver(promise_resolve_fn, [value], constructor)
          index = append_pending_all_value(state_ref)
          then = QuickBEAM.VM.ObjectModel.Get.get(next_promise, "then")

          unless QuickBEAM.VM.Builtin.callable?(then) do
            JSThrow.type_error!("Promise then is not callable")
          end

          Invocation.invoke_with_receiver(
            then,
            [
              once_function(fn settled ->
                fulfill_all_element(
                  state_ref,
                  resolve,
                  reject,
                  index,
                  Heap.wrap(%{"status" => "fulfilled", "value" => settled})
                )
              end),
              once_function(fn reason ->
                fulfill_all_element(
                  state_ref,
                  resolve,
                  reject,
                  index,
                  Heap.wrap(%{"status" => "rejected", "reason" => reason})
                )
              end)
            ],
            next_promise
          )

          perform_all_settled_loop(
            next_iter,
            next_fn,
            constructor,
            promise_resolve_fn,
            state_ref,
            resolve,
            reject
          )
        catch
          {:js_throw, reason} ->
            close_iterator_preserving_throw(next_iter)
            throw({:js_throw, reason})
        end
    end
  end

  defp perform_promise_any(constructor, iterable) do
    {promise, resolve, reject} = new_promise_capability(constructor)

    try do
      {iter, next_fn} = Iterators.for_of_start(iterable)
      promise_resolve_fn = QuickBEAM.VM.ObjectModel.Get.get(constructor, "resolve")

      unless QuickBEAM.VM.Builtin.callable?(promise_resolve_fn) do
        JSThrow.type_error!("Promise resolve is not callable")
      end

      state_ref = make_ref()
      Heap.put_obj(state_ref, %{"remaining" => 1, "errors" => []})
      perform_any_loop(iter, next_fn, constructor, promise_resolve_fn, state_ref, resolve, reject)
      promise
    catch
      {:js_throw, reason} ->
        Invocation.invoke(reject, [reason])
        promise
    end
  end

  defp perform_any_loop(
         iter,
         next_fn,
         constructor,
         promise_resolve_fn,
         state_ref,
         resolve,
         reject
       ) do
    case promise_for_of_next(next_fn, iter) do
      {true, _, _} ->
        state = Heap.get_obj(state_ref, %{})
        remaining = state["remaining"] - 1
        Heap.put_obj(state_ref, %{state | "remaining" => remaining})

        if remaining == 0 do
          Invocation.invoke(reject, [aggregate_error_from_list(state["errors"])])
        end

      {false, value, next_iter} ->
        try do
          next_promise = Invocation.invoke_with_receiver(promise_resolve_fn, [value], constructor)
          index = append_pending_any_error(state_ref)
          then = QuickBEAM.VM.ObjectModel.Get.get(next_promise, "then")

          unless QuickBEAM.VM.Builtin.callable?(then) do
            JSThrow.type_error!("Promise then is not callable")
          end

          Invocation.invoke_with_receiver(
            then,
            [
              resolve,
              once_function(fn reason ->
                reject_any_element_direct(state_ref, reject, index, reason)
              end)
            ],
            next_promise
          )

          perform_any_loop(
            next_iter,
            next_fn,
            constructor,
            promise_resolve_fn,
            state_ref,
            resolve,
            reject
          )
        catch
          {:js_throw, reason} ->
            close_iterator_preserving_throw(next_iter)
            throw({:js_throw, reason})
        end
    end
  end

  defp append_pending_any_error(state_ref) do
    state = Heap.get_obj(state_ref, %{})
    errors = state["errors"] ++ [:undefined]
    index = length(errors) - 1
    Heap.put_obj(state_ref, %{state | "errors" => errors, "remaining" => state["remaining"] + 1})
    index
  end

  defp reject_any_element_direct(state_ref, reject, index, reason) do
    state = Heap.get_obj(state_ref, %{})
    errors = List.replace_at(state["errors"], index, reason)
    remaining = state["remaining"] - 1
    Heap.put_obj(state_ref, %{state | "errors" => errors, "remaining" => remaining})

    if remaining == 0 do
      Invocation.invoke(reject, [aggregate_error_from_list(errors)])
    end

    :undefined
  end

  defp aggregate_error_from_list(errors) do
    {:obj, ref} = error = Heap.make_error("All promises were rejected", "AggregateError")
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), "errors", Heap.wrap(errors)))
    error
  end

  defp perform_promise_race(constructor, iterable) do
    {promise, resolve, reject} = new_promise_capability(constructor)

    try do
      {iter, next_fn} = Iterators.for_of_start(iterable)
      promise_resolve_fn = QuickBEAM.VM.ObjectModel.Get.get(constructor, "resolve")

      unless QuickBEAM.VM.Builtin.callable?(promise_resolve_fn) do
        JSThrow.type_error!("Promise resolve is not callable")
      end

      perform_race_loop(iter, next_fn, constructor, promise_resolve_fn, resolve, reject)
      promise
    catch
      {:js_throw, reason} ->
        Invocation.invoke(reject, [reason])
        promise
    end
  end

  defp perform_race_loop(iter, next_fn, constructor, promise_resolve_fn, resolve, reject) do
    case promise_for_of_next(next_fn, iter) do
      {true, _, _} ->
        :ok

      {false, value, next_iter} ->
        try do
          next_promise = Invocation.invoke_with_receiver(promise_resolve_fn, [value], constructor)
          then = QuickBEAM.VM.ObjectModel.Get.get(next_promise, "then")

          unless QuickBEAM.VM.Builtin.callable?(then) do
            JSThrow.type_error!("Promise then is not callable")
          end

          Invocation.invoke_with_receiver(
            then,
            [resolve, reject],
            next_promise
          )

          perform_race_loop(next_iter, next_fn, constructor, promise_resolve_fn, resolve, reject)
        catch
          {:js_throw, reason} ->
            close_iterator_preserving_throw(next_iter)
            throw({:js_throw, reason})
        end
    end
  end

  defp promise_resolve({:builtin, "Promise", _} = constructor, {:obj, ref} = value) do
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => state} when state in [:resolved, :rejected, :pending] ->
        if QuickBEAM.VM.ObjectModel.Get.get(value, "constructor") == constructor do
          value
        else
          Promise.resolved(value)
        end

      _ ->
        Promise.adopt(value)
    end
  end

  defp promise_resolve({:builtin, "Promise", _}, value), do: Promise.adopt(value)

  defp promise_resolve(constructor, value) do
    {promise, resolve, _reject} = new_promise_capability(constructor)
    Invocation.invoke(resolve, [value])
    promise
  end

  defp promise_reject({:builtin, "Promise", _}, reason), do: Promise.rejected(reason)

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

  defp promise_inputs(arr) do
    arr
    |> Heap.to_list()
    |> Enum.map(&Promise.adopt/1)
    |> Enum.map(&observe_input_then/1)
  end

  defp observe_input_then({:obj, _} = promise) do
    then = QuickBEAM.VM.ObjectModel.Get.get(promise, "then")

    if QuickBEAM.VM.Builtin.callable?(then) do
      Invocation.invoke_with_receiver(
        then,
        [
          resolving_function(fn _args -> :undefined end),
          resolving_function(fn _args -> :undefined end)
        ],
        promise
      )
    end

    promise
  end

  defp observe_input_then(value), do: value

  defp promise_all(arr), do: arr |> promise_inputs() |> promise_all_items()

  defp promise_all_items(items) do
    cond do
      rejection = first_rejection(items) ->
        {:rejected, reason} = rejection
        Promise.rejected(reason)

      pending_input?(items) ->
        Promise.pending()

      true ->
        results = Enum.map(items, &unwrap_value/1)
        Promise.resolved(Heap.wrap(results))
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

  defp promise_all_settled(arr), do: arr |> promise_inputs() |> promise_all_settled_items()

  defp promise_all_settled_items(items) do
    if pending_input?(items) do
      Promise.pending()
    else
      results = Enum.map(items, &settled_result/1)
      Promise.resolved(Heap.wrap(results))
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
          %{promise_state() => :resolved, promise_value() => {:obj, _} = values_obj} ->
            values = Heap.to_list(values_obj)

            result =
              entries
              |> Enum.zip(values)
              |> Enum.reduce(%{}, fn {{key, _}, value}, acc -> Map.put(acc, key, value) end)
              |> Heap.wrap()

            Promise.resolved(result)

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

  defp promise_any_items(items) do
    case first_fulfillment(items) do
      {:fulfilled, value} ->
        Promise.resolved(value)

      :none ->
        if(pending_input?(items),
          do: Promise.pending(),
          else: Promise.rejected(aggregate_error(items))
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
    Heap.put_obj(captured, %{"resolve" => :undefined, "reject" => :undefined})

    executor =
      capability_executor(fn args ->
        current = Heap.get_obj(captured, %{})

        if current["resolve"] != :undefined or current["reject"] != :undefined do
          JSThrow.type_error!("Promise capability executor already called")
        end

        Heap.put_obj(captured, %{
          "resolve" => arg(args, 0, :undefined),
          "reject" => arg(args, 1, :undefined)
        })

        :undefined
      end)

    promise = Invocation.construct_runtime(constructor, constructor, [executor])

    case Heap.get_obj(captured, %{}) do
      %{"resolve" => resolve, "reject" => reject}
      when resolve != :undefined and reject != :undefined ->
        unless QuickBEAM.VM.Builtin.callable?(resolve) and QuickBEAM.VM.Builtin.callable?(reject) do
          JSThrow.type_error!("Promise capability executor arguments must be callable")
        end

        {promise, resolve, reject}

      _ ->
        JSThrow.type_error!("Promise constructor did not provide resolving functions")
    end
  end

  defp capability_executor(callback) when is_function(callback, 1) do
    fun = {:builtin, "__promiseCapabilityExecutor", fn args, _ -> callback.(args) end}
    QuickBEAM.VM.Builtin.put_function_metadata(fun, "", 2)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  defp resolving_function(callback) when is_function(callback, 1) do
    fun = {:builtin, "resolve", fn args, _ -> callback.(args) end}
    QuickBEAM.VM.Builtin.put_function_metadata(fun, "", 1)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  defp once_function(callback) when is_function(callback, 1) do
    called_ref = make_ref()
    Heap.put_obj(called_ref, %{"called" => false})

    resolving_function(fn args ->
      case Heap.get_obj(called_ref, %{}) do
        %{"called" => true} ->
          :undefined

        _ ->
          Heap.put_obj(called_ref, %{"called" => true})
          callback.(arg(args, 0, :undefined))
      end
    end)
  end

  defp promise_race_items(items) do
    if items == [] do
      Promise.pending()
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
          Promise.resolved(v)

        {:err, v} ->
          Promise.rejected(v)

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
                         Promise.resolve(race_ref, :resolved, val)

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
                         Promise.resolve(race_ref, :rejected, reason)

                       _ ->
                         :ok
                     end

                     throw({:js_throw, reason})
                   end}

                Promise.promise_then([on_fulfilled, on_rejected], item)

              _ ->
                case Heap.get_obj(race_ref, %{}) do
                  %{promise_state() => :pending} ->
                    Promise.resolve(race_ref, :resolved, item)

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
