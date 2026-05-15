defmodule QuickBEAM.VM.Runtime.Iterator do
  @moduledoc "JavaScript Iterator constructor and basic wrapping support."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Builtin, Heap, Invocation, JSThrow}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Runtime

  def constructor do
    fn _args, this ->
      iterator_proto = Runtime.global_class_proto("Iterator")

      case this do
        {:obj, ref} = obj ->
          if Map.get(Heap.get_obj(ref, %{}), "__proto__") == iterator_proto do
            JSThrow.type_error!("Iterator is not constructible")
          else
            obj
          end

        _ ->
          JSThrow.type_error!("Iterator is not callable")
      end
    end
  end

  def static_property("from") do
    from = {:builtin, "from", &from/2}
    Heap.put_ctor_static(from, "length", 1)
    Heap.put_ctor_static(from, "name", "from")
    from
  end

  def static_property(_), do: :undefined

  def proto_property({:symbol, "Symbol.iterator"}) do
    {:builtin, "[Symbol.iterator]", fn _args, this -> this end}
  end

  def proto_property("drop"), do: method("drop", 1, &drop/2)
  def proto_property("filter"), do: method("filter", 1, &filter/2)
  def proto_property("flatMap"), do: method("flatMap", 1, &flat_map/2)
  def proto_property("forEach"), do: method("forEach", 1, &for_each/2)
  def proto_property("map"), do: method("map", 1, &map/2)
  def proto_property("every"), do: method("every", 1, &every/2)
  def proto_property("find"), do: method("find", 1, &find/2)

  def proto_property(_), do: :undefined

  defp method(name, length, callback) do
    fun = {:builtin, name, callback}
    Heap.put_ctor_static(fun, "length", length)
    Heap.put_ctor_static(fun, "name", name)
    fun
  end

  def from([value | _], _this), do: from_value(value)
  def from(_, _this), do: JSThrow.type_error!("Iterator.from requires an object")

  defp from_value(value) do
    unless object_like?(value), do: JSThrow.type_error!("Iterator.from requires an object")

    iterator_method = Get.get(value, {:symbol, "Symbol.iterator"})

    iterator =
      if Builtin.callable?(iterator_method) do
        result = Invocation.invoke_with_receiver(iterator_method, [], value)

        unless object_like?(result),
          do: JSThrow.type_error!("iterator method returned non-object")

        result
      else
        value
      end

    if iterator_method != :undefined and iterator_method != nil and iterator == value do
      iterator
    else
      wrap_iterator(iterator)
    end
  end

  defp wrap_iterator(iterator) do
    proto = wrap_for_valid_iterator_prototype()

    Heap.wrap(%{
      "__proto__" => proto,
      "__wrapped_iterator__" => iterator,
      "next" => {:builtin, "next", fn _args, this -> wrapper_next(this) end},
      "return" => {:builtin, "return", fn _args, this -> wrapper_return(this) end},
      {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _args, this -> this end}
    })
  end

  def wrap_for_valid_iterator_prototype do
    proto = Runtime.global_class_proto("Iterator")

    case Process.get(:qb_wrap_for_valid_iterator_prototype) do
      {:obj, _} = cached ->
        cached

      _ ->
        wrapper =
          Heap.wrap(%{
            "__proto__" => proto,
            "next" => {:builtin, "next", fn _args, this -> wrapper_next(this) end},
            "return" => {:builtin, "return", fn _args, this -> wrapper_return(this) end},
            {:symbol, "Symbol.iterator"} =>
              {:builtin, "[Symbol.iterator]", fn _args, this -> this end}
          })

        Process.put(:qb_wrap_for_valid_iterator_prototype, wrapper)
        wrapper
    end
  end

  def drop(args, this) do
    iterator = iterator_record(this)
    remaining = non_negative_integer_limit(Builtin.arg(args, 0, :undefined))
    helper_iterator(%{"kind" => :drop, "iterator" => iterator, "remaining" => remaining})
  end

  def filter(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(predicate), do: JSThrow.type_error!("predicate must be callable")

    helper_iterator(%{
      "kind" => :filter,
      "iterator" => iterator_record(this),
      "predicate" => predicate,
      "index" => 0
    })
  end

  def map(args, this) do
    mapper = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(mapper), do: JSThrow.type_error!("mapper must be callable")

    helper_iterator(%{
      "kind" => :map,
      "iterator" => iterator_record(this),
      "mapper" => mapper,
      "index" => 0
    })
  end

  def flat_map(args, this) do
    mapper = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(mapper), do: JSThrow.type_error!("mapper must be callable")

    helper_iterator(%{
      "kind" => :flat_map,
      "iterator" => iterator_record(this),
      "mapper" => mapper,
      "index" => 0,
      "inner" => nil
    })
  end

  def for_each(args, this) do
    callback = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(callback), do: JSThrow.type_error!("callback must be callable")
    for_each_loop(iterator_record(this), callback, 0)
    :undefined
  end

  def every(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(predicate), do: JSThrow.type_error!("predicate must be callable")
    every_loop(iterator_record(this), predicate, 0)
  end

  def find(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(predicate), do: JSThrow.type_error!("predicate must be callable")
    find_loop(iterator_record(this), predicate, 0)
  end

  defp helper_iterator(state) do
    state_ref = make_ref()
    Heap.put_obj(state_ref, state)

    Heap.wrap(%{
      "__proto__" => wrap_for_valid_iterator_prototype(),
      "__iterator_helper_state__" => state_ref,
      "next" => {:builtin, "next", fn _args, this -> helper_next(this) end},
      "return" => {:builtin, "return", fn _args, this -> helper_return(this) end},
      {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _args, this -> this end}
    })
  end

  defp helper_next({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__iterator_helper_state__" => state_ref} -> helper_next_state(state_ref)
      _ -> JSThrow.type_error!("Iterator helper expected")
    end
  end

  defp helper_next(_), do: JSThrow.type_error!("Iterator helper expected")

  defp helper_next_state(state_ref) do
    state = Heap.get_obj(state_ref, %{})

    case state["kind"] do
      :drop -> drop_next(state_ref, state)
      :filter -> filter_next(state_ref, state)
      :map -> map_next(state_ref, state)
      :flat_map -> flat_map_next(state_ref, state)
      _ -> iter_result(:undefined, true)
    end
  end

  defp drop_next(state_ref, %{"iterator" => iterator, "remaining" => remaining} = state) do
    skip_dropped(iterator, remaining)
    Heap.put_obj(state_ref, %{state | "remaining" => 0})
    iterator_next(iterator)
  end

  defp skip_dropped(_iterator, remaining) when is_number(remaining) and remaining <= 0, do: :ok

  defp skip_dropped(iterator, remaining) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      :ok
    else
      next_remaining = if remaining == :infinity, do: :infinity, else: remaining - 1
      skip_dropped(iterator, next_remaining)
    end
  end

  defp filter_next(
         state_ref,
         %{"iterator" => iterator, "predicate" => predicate, "index" => index} = state
       ) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      result
    else
      value = Get.get(result, "value")
      keep = Invocation.invoke_with_receiver(predicate, [value, index], :undefined)
      Heap.put_obj(state_ref, %{state | "index" => index + 1})

      if Values.truthy?(keep) do
        iter_result(value, false)
      else
        filter_next(state_ref, Heap.get_obj(state_ref, %{}))
      end
    end
  end

  defp map_next(
         state_ref,
         %{"iterator" => iterator, "mapper" => mapper, "index" => index} = state
       ) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      result
    else
      value = Get.get(result, "value")
      mapped = Invocation.invoke_with_receiver(mapper, [value, index], :undefined)
      Heap.put_obj(state_ref, %{state | "index" => index + 1})
      iter_result(mapped, false)
    end
  end

  defp flat_map_next(state_ref, state) do
    case next_inner_value(state["inner"]) do
      {:ok, value} ->
        iter_result(value, false)

      :done ->
        outer = iterator_next(state["iterator"])

        if Get.get(outer, "done") == true do
          outer
        else
          value = Get.get(outer, "value")
          index = state["index"]
          mapped = Invocation.invoke_with_receiver(state["mapper"], [value, index], :undefined)
          inner = iterator_record_from_value(mapped)
          Heap.put_obj(state_ref, %{state | "index" => index + 1, "inner" => inner})
          flat_map_next(state_ref, Heap.get_obj(state_ref, %{}))
        end
    end
  end

  defp next_inner_value(nil), do: :done

  defp next_inner_value(iterator) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      :done
    else
      {:ok, Get.get(result, "value")}
    end
  end

  defp iterator_record_from_value(value) do
    wrapped = from_value(value)
    iterator_record(wrapped)
  end

  defp for_each_loop(iterator, callback, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      :ok
    else
      value = Get.get(result, "value")
      Invocation.invoke_with_receiver(callback, [value, index], :undefined)
      for_each_loop(iterator, callback, index + 1)
    end
  end

  defp every_loop(iterator, predicate, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      true
    else
      value = Get.get(result, "value")
      keep = Invocation.invoke_with_receiver(predicate, [value, index], :undefined)

      if Values.truthy?(keep) do
        every_loop(iterator, predicate, index + 1)
      else
        iterator_return(iterator)
        false
      end
    end
  end

  defp find_loop(iterator, predicate, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      :undefined
    else
      value = Get.get(result, "value")
      keep = Invocation.invoke_with_receiver(predicate, [value, index], :undefined)

      if Values.truthy?(keep) do
        iterator_return(iterator)
        value
      else
        find_loop(iterator, predicate, index + 1)
      end
    end
  end

  defp helper_return({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__iterator_helper_state__" => state_ref} ->
        state = Heap.get_obj(state_ref, %{})
        iterator_return(state["iterator"])
        iter_result(:undefined, true)

      _ ->
        JSThrow.type_error!("Iterator helper expected")
    end
  end

  defp helper_return(_), do: JSThrow.type_error!("Iterator helper expected")

  defp iterator_record(this) do
    unless object_like?(this), do: JSThrow.type_error!("Iterator receiver must be an object")
    next = Get.get(this, "next")
    unless Builtin.callable?(next), do: JSThrow.type_error!("Iterator next is not callable")
    %{"iterator" => this, "next" => next}
  end

  defp iterator_next(%{"iterator" => iterator, "next" => next}) do
    result = Invocation.invoke_with_receiver(next, [], iterator)
    unless object_like?(result), do: JSThrow.type_error!("Iterator result is not an object")
    result
  end

  defp iterator_return(%{"iterator" => iterator}) do
    return_method = Get.get(iterator, "return")

    if Builtin.callable?(return_method) do
      Invocation.invoke_with_receiver(return_method, [], iterator)
    else
      iter_result(:undefined, true)
    end
  end

  defp iter_result(value, done), do: Heap.wrap(%{"value" => value, "done" => done})

  defp non_negative_integer_limit(value) do
    number = Runtime.to_number(value)

    cond do
      number == :infinity -> :infinity
      number in [:nan, :neg_infinity] -> JSThrow.range_error!("invalid limit")
      not is_number(number) -> JSThrow.range_error!("invalid limit")
      number < 0 -> JSThrow.range_error!("invalid limit")
      true -> trunc(number)
    end
  end

  defp wrapper_next(this), do: call_wrapped(this, "next", [])

  defp wrapper_return(this) do
    iterator = wrapped_iterator!(this)
    return_method = Get.get(iterator, "return")

    if Builtin.callable?(return_method) do
      Invocation.invoke_with_receiver(return_method, [], iterator)
    else
      Heap.wrap(%{"value" => :undefined, "done" => true})
    end
  end

  defp call_wrapped(this, name, args) do
    iterator = wrapped_iterator!(this)
    method = Get.get(iterator, name)
    unless Builtin.callable?(method), do: JSThrow.type_error!("Iterator method is not callable")
    result = Invocation.invoke_with_receiver(method, args, iterator)
    unless object_like?(result), do: JSThrow.type_error!("Iterator result is not an object")
    result
  end

  defp wrapped_iterator!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__wrapped_iterator__" => iterator} -> iterator
      _ -> JSThrow.type_error!("Iterator wrapper expected")
    end
  end

  defp wrapped_iterator!(_), do: JSThrow.type_error!("Iterator wrapper expected")

  defp object_like?({:obj, _}), do: true
  defp object_like?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp object_like?(%QuickBEAM.VM.Function{}), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?({:bound, _, _, _, _}), do: true
  defp object_like?({:regexp, _, _}), do: true
  defp object_like?({:regexp, _, _, _}), do: true
  defp object_like?(_), do: false
end
