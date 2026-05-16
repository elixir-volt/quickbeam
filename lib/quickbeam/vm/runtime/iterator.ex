defmodule QuickBEAM.VM.Runtime.Iterator do
  @moduledoc "JavaScript Iterator constructor and basic wrapping support."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0]

  alias QuickBEAM.VM.{Builtin, Heap, Invocation, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{Get, OwnProperty, PropertyDescriptor, Put, WrappedPrimitive}
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

  def static_property("from"), do: static_method("from", 1, &from/2)
  def static_property("concat"), do: static_method("concat", 0, &concat/2)
  def static_property("zip"), do: static_method("zip", 1, &zip/2)
  def static_property("zipKeyed"), do: static_method("zipKeyed", 1, &zip_keyed/2)

  def static_property(_), do: :undefined

  defp static_method(name, length, callback) do
    fun = {:builtin, name, callback}
    Heap.put_ctor_static(fun, "length", length)
    Heap.put_ctor_static(fun, "name", name)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  def proto_property({:symbol, "Symbol.iterator"}) do
    {:builtin, "[Symbol.iterator]", fn _args, this -> this end}
  end

  def proto_property({:symbol, "Symbol.dispose"}), do: method("[Symbol.dispose]", 0, &dispose/2)
  def proto_property({:symbol, "Symbol.toStringTag"}), do: iterator_proto_accessor(:to_string_tag)
  def proto_property("constructor"), do: iterator_proto_accessor(:constructor)

  def proto_property("drop"), do: method("drop", 1, &drop/2)
  def proto_property("filter"), do: method("filter", 1, &filter/2)
  def proto_property("flatMap"), do: method("flatMap", 1, &flat_map/2)
  def proto_property("forEach"), do: method("forEach", 1, &for_each/2)
  def proto_property("map"), do: method("map", 1, &map/2)
  def proto_property("reduce"), do: method("reduce", 1, &reduce/2)
  def proto_property("some"), do: method("some", 1, &some/2)
  def proto_property("take"), do: method("take", 1, &take/2)
  def proto_property("toArray"), do: method("toArray", 0, &to_array/2)
  def proto_property("every"), do: method("every", 1, &every/2)
  def proto_property("find"), do: method("find", 1, &find/2)

  def proto_property(_), do: :undefined

  defp method(name, length, callback) do
    fun = {:builtin, name, callback}
    Heap.put_ctor_static(fun, "length", length)
    Heap.put_ctor_static(fun, "name", name)
    Heap.put_ctor_prop_desc(fun, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(fun, "name", PropertyDescriptor.hidden_readonly())
    fun
  end

  def from([value | _], _this), do: from_value(value)
  def from(_, _this), do: JSThrow.type_error!("Iterator.from requires an object")

  def iterator_proto_accessor(:constructor) do
    getter =
      {:builtin, "get constructor", fn _args, _this -> Runtime.global_constructor("Iterator") end}

    setter =
      {:builtin, "set constructor",
       fn [value | _], this -> set_iterator_proto_slot(this, "constructor", value) end}

    {:accessor, getter, setter}
  end

  def iterator_proto_accessor(:to_string_tag) do
    getter = {:builtin, "get [Symbol.toStringTag]", fn _args, _this -> "Iterator" end}

    setter =
      {:builtin, "set [Symbol.toStringTag]",
       fn [value | _], this ->
         set_iterator_proto_slot(this, {:symbol, "Symbol.toStringTag"}, value)
       end}

    {:accessor, getter, setter}
  end

  defp set_iterator_proto_slot({:obj, ref} = this, key, value) do
    if this == Runtime.global_class_proto("Iterator") do
      JSThrow.type_error!("Cannot set Iterator prototype intrinsic property")
    end

    if Heap.get_prop_desc(ref, key) == nil do
      Heap.put_obj_key(ref, key, value)
      Heap.put_prop_desc(ref, key, PropertyDescriptor.enumerable_data())
    else
      Put.set(this, key, value, this)
    end

    :undefined
  end

  defp set_iterator_proto_slot(_, _key, _value),
    do: JSThrow.type_error!("Iterator prototype setter receiver must be an object")

  def dispose(_args, this) do
    return_method = Get.get(this, "return")

    if Builtin.callable?(return_method) do
      Invocation.invoke_with_receiver(return_method, [], this)
    end

    :undefined
  end

  def concat(args, _this) do
    iterables = Enum.map(args, &concat_iterable_record/1)
    helper_iterator(%{"kind" => :concat, "iterables" => iterables, "index" => 0, "active" => nil})
  end

  def zip(args, _this) do
    source = Builtin.arg(args, 0, [])
    options = Builtin.arg(args, 1, :undefined)
    helper_iterator(zip_state_from_source(source, nil, options))
  end

  def zip_keyed(args, _this) do
    source = Builtin.arg(args, 0, [])
    options = Builtin.arg(args, 1, :undefined)
    options = zip_options_object(options)
    mode = zip_mode(options)
    padding_option = zip_padding_option(options, mode)
    {keys, iterators} = keyed_iterator_records(source)
    helper_iterator(zip_state_from_iterators(iterators, keys, mode, padding_option))
  end

  defp from_value(value) when is_binary(value) do
    case string_iterator_method(value) do
      method when method != :undefined ->
        iterator = Invocation.invoke_with_receiver(method, [], value)

        unless object_like?(iterator),
          do: JSThrow.type_error!("iterator method returned non-object")

        wrap_iterator(iterator)

      :undefined ->
        value
        |> String.graphemes()
        |> list_iterator()
    end
  end

  defp from_value(value) when is_list(value), do: list_iterator(value)

  defp from_value(value) do
    unless object_like?(value), do: JSThrow.type_error!("Iterator.from requires an object")

    iterator_method =
      string_object_iterator_method(value) || Get.get(value, {:symbol, "Symbol.iterator"})

    iterator =
      cond do
        Builtin.callable?(iterator_method) ->
          result = Invocation.invoke_with_receiver(iterator_method, [], value)

          unless object_like?(result),
            do: JSThrow.type_error!("iterator method returned non-object")

          result

        iterator_method in [:undefined, nil] ->
          value

        true ->
          JSThrow.type_error!("iterator method is not callable")
      end

    if iterator_method != :undefined and iterator_method != nil and iterator == value do
      iterator
    else
      wrap_iterator(iterator)
    end
  end

  defp string_object_iterator_method({:obj, ref} = receiver) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        if WrappedPrimitive.type(map) == :string do
          string_iterator_method(receiver)
        end

      _ ->
        nil
    end
  end

  defp string_object_iterator_method(_), do: nil

  defp string_iterator_method(receiver) do
    case Runtime.global_class_proto("String") do
      {:obj, proto_ref} ->
        case Heap.get_obj(proto_ref, %{}) do
          %{{:symbol, "Symbol.iterator"} => {:accessor, getter, _setter}} when getter != nil ->
            Get.call_getter(getter, receiver)

          %{{:symbol, "Symbol.iterator"} => value} ->
            value

          _ ->
            :undefined
        end

      _ ->
        :undefined
    end
  end

  defp list_iterator(items) do
    state_ref = make_ref()
    Heap.put_obj(state_ref, %{"items" => items, "index" => 0})

    Heap.wrap(%{
      "__proto__" => wrap_for_valid_iterator_prototype(),
      "next" => {:builtin, "next", fn _args, _this -> list_iterator_next(state_ref) end},
      "return" => {:builtin, "return", fn _args, _this -> iter_result(:undefined, true) end},
      {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _args, this -> this end}
    })
  end

  defp list_iterator_next(state_ref) do
    state = Heap.get_obj(state_ref, %{})
    index = state["index"]
    items = state["items"]

    if index >= length(items) do
      iter_result(:undefined, true)
    else
      Heap.put_obj(state_ref, %{state | "index" => index + 1})
      iter_result(Enum.at(items, index), false)
    end
  end

  defp wrap_iterator(iterator) do
    proto = wrap_for_valid_iterator_prototype()
    next = Get.get(iterator, "next")

    Heap.wrap(%{
      "__proto__" => proto,
      "__wrapped_iterator__" => iterator,
      "__wrapped_next__" => next,
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
    unless object_like?(this), do: JSThrow.type_error!("Iterator receiver must be an object")
    remaining = non_negative_integer_limit_or_close(this, Builtin.arg(args, 0, :undefined))
    iterator = iterator_direct_record(this)
    helper_iterator(%{"kind" => :drop, "iterator" => iterator, "remaining" => remaining})
  end

  def take(args, this) do
    unless object_like?(this), do: JSThrow.type_error!("Iterator receiver must be an object")
    remaining = non_negative_integer_limit_or_close(this, Builtin.arg(args, 0, :undefined))
    iterator = iterator_direct_record(this)
    helper_iterator(%{"kind" => :take, "iterator" => iterator, "remaining" => remaining})
  end

  def filter(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)

    unless Builtin.callable?(predicate),
      do: close_and_type_error(this, "predicate must be callable")

    helper_iterator(%{
      "kind" => :filter,
      "iterator" => iterator_direct_record(this),
      "predicate" => predicate,
      "index" => 0
    })
  end

  def map(args, this) do
    mapper = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(mapper), do: close_and_type_error(this, "mapper must be callable")

    helper_iterator(%{
      "kind" => :map,
      "iterator" => iterator_direct_record(this),
      "mapper" => mapper,
      "index" => 0
    })
  end

  def flat_map(args, this) do
    mapper = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(mapper), do: close_and_type_error(this, "mapper must be callable")

    helper_iterator(%{
      "kind" => :flat_map,
      "iterator" => iterator_direct_record(this),
      "mapper" => mapper,
      "index" => 0,
      "inner" => nil
    })
  end

  def some(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)

    unless Builtin.callable?(predicate),
      do: close_and_type_error(this, "predicate must be callable")

    some_loop(iterator_direct_record(this), predicate, 0)
  end

  def reduce(args, this) do
    reducer = Builtin.arg(args, 0, :undefined)
    unless Builtin.callable?(reducer), do: close_and_type_error(this, "reducer must be callable")

    iterator = iterator_direct_record(this)

    case args do
      [_reducer, initial | _] -> reduce_loop(iterator, reducer, initial, 0)
      _ -> reduce_without_initial(iterator, reducer)
    end
  end

  def to_array(_args, this) do
    this
    |> iterator_record()
    |> collect_values([])
    |> Enum.reverse()
    |> Heap.wrap()
  end

  def for_each(args, this) do
    callback = Builtin.arg(args, 0, :undefined)

    unless Builtin.callable?(callback),
      do: close_and_type_error(this, "callback must be callable")

    for_each_loop(iterator_direct_record(this), callback, 0)
    :undefined
  end

  def every(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)

    unless Builtin.callable?(predicate),
      do: close_and_type_error(this, "predicate must be callable")

    every_loop(iterator_direct_record(this), predicate, 0)
  end

  def find(args, this) do
    predicate = Builtin.arg(args, 0, :undefined)

    unless Builtin.callable?(predicate),
      do: close_and_type_error(this, "predicate must be callable")

    find_loop(iterator_direct_record(this), predicate, 0)
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

    if state["kind"] == :done do
      iter_result(:undefined, true)
    else
      if state["executing"] == true do
        JSThrow.type_error!("Iterator helper is already running")
      end

      Heap.put_obj(state_ref, Map.put(state, "executing", true))

      try do
        result = helper_next_kind(state_ref, Heap.get_obj(state_ref, %{}))
        finish_helper_execution(state_ref)
        result
      catch
        kind, reason ->
          finish_helper_execution(state_ref)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp helper_next_kind(state_ref, state) do
    case state["kind"] do
      :concat -> concat_next(state_ref, state)
      :zip -> zip_next(state_ref, state)
      :drop -> drop_next(state_ref, state)
      :take -> take_next(state_ref, state)
      :filter -> filter_next(state_ref, state)
      :map -> map_next(state_ref, state)
      :flat_map -> flat_map_next(state_ref, state)
      _ -> iter_result(:undefined, true)
    end
  end

  defp finish_helper_execution(state_ref) do
    state = Heap.get_obj(state_ref, %{})

    if state["kind"] != :done do
      Heap.put_obj(state_ref, Map.put(state, "executing", false))
    end
  end

  defp zip_state_from_source(source, keys, options) do
    options = zip_options_object(options)
    mode = zip_mode(options)
    padding_option = zip_padding_option(options, mode)
    iterables = zip_outer_values(source)
    zip_state(iterables, keys, mode, padding_option)
  end

  defp zip_state(iterables, keys, mode, padding_option) do
    iterators = Enum.map(iterables, &(from_value(&1) |> iterator_record()))
    zip_state_from_iterators(iterators, keys, mode, padding_option)
  end

  defp zip_state_from_iterators(iterators, keys, mode, padding_option) do
    padding =
      try do
        zip_padding_values(padding_option, mode, keys, length(iterators))
      catch
        kind, reason ->
          close_iterators_ignoring_errors(iterators)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    %{
      "kind" => :zip,
      "iterators" => iterators,
      "keys" => keys,
      "mode" => mode,
      "padding" => padding
    }
  end

  defp zip_options_object(:undefined), do: :undefined

  defp zip_options_object(options) when is_nil(options),
    do: JSThrow.type_error!("Iterator.zip options must be an object")

  defp zip_options_object(options) do
    if object_like?(options) do
      options
    else
      JSThrow.type_error!("Iterator.zip options must be an object")
    end
  end

  defp zip_mode(:undefined), do: :shortest

  defp zip_mode(options) do
    case Get.get(options, "mode") do
      :undefined -> :shortest
      "shortest" -> :shortest
      "longest" -> :longest
      "strict" -> :strict
      _ -> JSThrow.type_error!("invalid Iterator.zip mode")
    end
  end

  defp zip_padding_option(_options, mode) when mode in [:shortest, :strict], do: :undefined
  defp zip_padding_option(:undefined, :longest), do: :undefined

  defp zip_padding_option(options, :longest) do
    case Get.get(options, "padding") do
      nil -> JSThrow.type_error!("Iterator.zip padding must be an object")
      value -> value
    end
  end

  defp zip_padding_values(_padding_option, mode, _keys, _count) when mode in [:shortest, :strict],
    do: []

  defp zip_padding_values(:undefined, :longest, _keys, _count), do: []

  defp zip_padding_values(padding_option, :longest, keys, count),
    do: validate_padding(padding_option, keys, count)

  defp validate_padding(value, nil, count), do: validate_padding_iterable(value, count)

  defp validate_padding(value, keys, _count) do
    unless object_like?(value), do: JSThrow.type_error!("Iterator.zip padding must be an object")
    Enum.map(keys, &Get.get(value, &1))
  end

  defp validate_padding_iterable(value, count) do
    unless object_like?(value), do: JSThrow.type_error!("Iterator.zip padding must be an object")
    collect_padding_values(zip_outer_iterator(value), count, [])
  end

  defp collect_padding_values(iterator, 0, acc) do
    iterator_return(iterator)
    Enum.reverse(acc)
  end

  defp collect_padding_values(iterator, count, acc) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      collect_padding_values(iterator, count - 1, [Get.get(result, "value") | acc])
    end
  end

  defp zip_outer_values(value), do: collect_zip_outer_values(zip_outer_iterator(value), [])

  defp zip_outer_iterator(value) do
    unless object_like?(value),
      do: JSThrow.type_error!("Iterator.zip iterables must be an object")

    method = Get.get(value, {:symbol, "Symbol.iterator"})

    unless Builtin.callable?(method),
      do: JSThrow.type_error!("Iterator.zip iterables must be iterable")

    iterator = Invocation.invoke_with_receiver(method, [], value)
    unless object_like?(iterator), do: JSThrow.type_error!("iterator method returned non-object")
    iterator_record(iterator)
  end

  defp collect_zip_outer_values(iterator, acc) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      collect_zip_outer_values(iterator, [Get.get(result, "value") | acc])
    end
  end

  defp keyed_iterator_records(value) do
    case value do
      {:obj, _} = obj ->
        obj
        |> OwnProperty.descriptor_keys()
        |> Enum.reduce({[], []}, fn key, {keys, iterators} = acc ->
          if internal_key?(key) do
            acc
          else
            desc =
              try do
                OwnProperty.descriptor(obj, key)
              catch
                kind, reason ->
                  close_iterators_ignoring_errors(Enum.reverse(iterators))
                  :erlang.raise(kind, reason, __STACKTRACE__)
              end

            if desc != :undefined and Get.get(desc, "enumerable") == true do
              value =
                try do
                  Get.get(obj, key)
                catch
                  kind, reason ->
                    close_iterators_ignoring_errors(Enum.reverse(iterators))
                    :erlang.raise(kind, reason, __STACKTRACE__)
                end

              if value == :undefined do
                acc
              else
                record =
                  try do
                    zip_keyed_value_record(value)
                  catch
                    kind, reason ->
                      close_iterators_ignoring_errors(Enum.reverse(iterators))
                      :erlang.raise(kind, reason, __STACKTRACE__)
                  end

                {[key | keys], [record | iterators]}
              end
            else
              acc
            end
          end
        end)
        |> then(fn {keys, iterators} -> {Enum.reverse(keys), Enum.reverse(iterators)} end)

      _ ->
        values = Heap.to_list(value)

        keys =
          values
          |> Enum.with_index()
          |> Enum.map(fn {_item, index} -> Integer.to_string(index) end)

        iterators = Enum.map(values, &zip_keyed_value_record/1)
        {keys, iterators}
    end
  end

  defp zip_keyed_value_record(value) when is_list(value),
    do: value |> from_value() |> iterator_record()

  defp zip_keyed_value_record(value) do
    unless object_like?(value),
      do: JSThrow.type_error!("Iterator.zipKeyed item must be an object")

    value |> from_value() |> iterator_record()
  end

  defp internal_key?(key) when is_binary(key), do: String.starts_with?(key, "__")
  defp internal_key?(_), do: false

  defp concat_iterable_record(item) do
    unless object_like?(item), do: JSThrow.type_error!("Iterator.concat item must be an object")
    method = Get.get(item, {:symbol, "Symbol.iterator"})

    unless Builtin.callable?(method),
      do: JSThrow.type_error!("Iterator.concat item is not iterable")

    %{"iterable" => item, "method" => method}
  end

  defp zip_next(_state_ref, %{"iterators" => []}), do: iter_result(:undefined, true)

  defp zip_next(_state_ref, %{"iterators" => iterators, "mode" => :shortest} = state) do
    case zip_step_shortest(iterators, [], []) do
      :done -> iter_result(:undefined, true)
      results -> zip_result(state["keys"], Enum.map(results, &Get.get(&1, "value")))
    end
  end

  defp zip_next(_state_ref, %{"iterators" => iterators, "mode" => :strict} = state) do
    case zip_step_strict(iterators, [], [], nil) do
      :done -> iter_result(:undefined, true)
      results -> zip_result(state["keys"], Enum.map(results, &Get.get(&1, "value")))
    end
  end

  defp zip_next(
         _state_ref,
         %{"iterators" => iterators, "mode" => :longest, "padding" => padding} = state
       ) do
    results = zip_step_all(iterators)

    if Enum.all?(results, &(Get.get(&1, "done") == true)) do
      iter_result(:undefined, true)
    else
      values =
        results
        |> Enum.with_index()
        |> Enum.map(fn {result, index} ->
          if Get.get(result, "done") == true do
            Enum.at(padding, index, :undefined)
          else
            Get.get(result, "value")
          end
        end)

      zip_result(state["keys"], values)
    end
  end

  defp zip_step_strict([], _previous_open, acc, nil), do: Enum.reverse(acc)
  defp zip_step_strict([], _previous_open, acc, :open), do: Enum.reverse(acc)
  defp zip_step_strict([], _previous_open, _acc, :done), do: :done

  defp zip_step_strict([iterator | rest], previous_open, acc, seen) do
    result =
      try do
        iterator_next(iterator)
      catch
        kind, reason ->
          close_iterators_ignoring_errors(rest)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    done? = Get.get(result, "done") == true

    cond do
      seen == nil and done? ->
        zip_step_strict(rest, previous_open, [result | acc], :done)

      seen == nil ->
        zip_step_strict(rest, [iterator | previous_open], [result | acc], :open)

      seen == :open and done? ->
        close_iterators_ignoring_errors(Enum.reverse(previous_open) ++ rest)
        JSThrow.type_error!("Iterator.zip strict mode length mismatch")

      seen == :open ->
        zip_step_strict(rest, [iterator | previous_open], [result | acc], :open)

      seen == :done and done? ->
        zip_step_strict(rest, previous_open, [result | acc], :done)

      seen == :done ->
        close_iterators_ignoring_errors([iterator | rest])
        JSThrow.type_error!("Iterator.zip strict mode length mismatch")
    end
  end

  defp zip_step_shortest([], _previous, acc), do: Enum.reverse(acc)

  defp zip_step_shortest([iterator | rest], previous, acc) do
    result =
      try do
        iterator_next(iterator)
      catch
        kind, reason ->
          close_iterators_ignoring_errors(rest)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    if Get.get(result, "done") == true do
      close_iterators_for_completion(previous ++ rest)
      :done
    else
      zip_step_shortest(rest, [iterator | previous], [result | acc])
    end
  end

  defp zip_step_all(iterators), do: zip_step_all(iterators, iterators, [])

  defp zip_step_all([], _all, acc), do: Enum.reverse(acc)

  defp zip_step_all([iterator | rest], all, acc) do
    result =
      try do
        iterator_next(iterator)
      catch
        kind, reason ->
          close_iterators_ignoring_errors(rest)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    zip_step_all(rest, all, [result | acc])
  end

  defp zip_result(nil, values), do: iter_result(Heap.wrap(values), false)

  defp zip_result(keys, values) do
    object =
      keys
      |> Enum.zip(values)
      |> Enum.reduce(%{"__proto__" => :null_proto}, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    iter_result(Heap.wrap(object), false)
  end

  defp concat_next(state_ref, %{"iterables" => iterables, "index" => index})
       when index >= length(iterables) do
    mark_helper_done(state_ref)
    iter_result(:undefined, true)
  end

  defp concat_next(
         state_ref,
         %{"active" => nil, "iterables" => iterables, "index" => index} = state
       ) do
    %{"iterable" => iterable, "method" => method} = Enum.at(iterables, index)
    iterator = Invocation.invoke_with_receiver(method, [], iterable)
    unless object_like?(iterator), do: JSThrow.type_error!("iterator method returned non-object")
    record = iterator_record(iterator)
    Heap.put_obj(state_ref, %{state | "active" => record})
    concat_next(state_ref, Heap.get_obj(state_ref, %{}))
  end

  defp concat_next(state_ref, %{"active" => iterator, "index" => index} = state) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      Heap.put_obj(state_ref, %{state | "index" => index + 1, "active" => nil})
      concat_next(state_ref, Heap.get_obj(state_ref, %{}))
    else
      iter_result(Get.get(result, "value"), false)
    end
  end

  defp take_next(state_ref, %{"iterator" => iterator, "remaining" => remaining})
       when is_number(remaining) and remaining <= 0 do
    mark_helper_done(state_ref)
    iterator_return(iterator)
    iter_result(:undefined, true)
  end

  defp take_next(state_ref, %{"iterator" => iterator, "remaining" => remaining} = state) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      mark_helper_done(state_ref)
      result
    else
      next_remaining = if remaining == :infinity, do: :infinity, else: remaining - 1
      Heap.put_obj(state_ref, %{state | "remaining" => next_remaining})
      iter_result(Get.get(result, "value"), false)
    end
  end

  defp drop_next(state_ref, %{"iterator" => iterator, "remaining" => remaining} = state) do
    if skip_dropped(iterator, remaining) == :done do
      mark_helper_done(state_ref)
      iter_result(:undefined, true)
    else
      Heap.put_obj(state_ref, %{state | "remaining" => 0})
      result = iterator_next(iterator)

      if Get.get(result, "done") == true do
        mark_helper_done(state_ref)
      end

      result
    end
  end

  defp skip_dropped(_iterator, remaining) when is_number(remaining) and remaining <= 0, do: :ok

  defp skip_dropped(iterator, remaining) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      :done
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
      mark_helper_done(state_ref)
      result
    else
      value = Get.get(result, "value")
      keep = invoke_or_close(iterator, predicate, [value, index])
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
      mark_helper_done(state_ref)
      result
    else
      value = Get.get(result, "value")
      mapped = invoke_or_close(iterator, mapper, [value, index])
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
          mark_helper_done(state_ref)
          outer
        else
          value = Get.get(outer, "value")
          index = state["index"]
          mapped = invoke_or_close(state["iterator"], state["mapper"], [value, index])
          inner = flattenable_iterator_record_or_close(state["iterator"], mapped)
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

  defp flattenable_iterator_record_or_close(iterator, value) do
    flattenable_iterator_record(value)
  catch
    {:js_throw, _} = reason ->
      close_record_preserving_reason(iterator)
      throw(reason)
  end

  defp flattenable_iterator_record(value) do
    unless object_like?(value),
      do: JSThrow.type_error!("Iterator mapper result must be an object")

    iterator_method = Get.get(value, {:symbol, "Symbol.iterator"})

    cond do
      Builtin.callable?(iterator_method) ->
        result = Invocation.invoke_with_receiver(iterator_method, [], value)

        unless object_like?(result),
          do: JSThrow.type_error!("iterator method returned non-object")

        iterator_record(result)

      iterator_method in [:undefined, nil] ->
        iterator_record(value)

      true ->
        JSThrow.type_error!("iterator method is not callable")
    end
  end

  defp for_each_loop(iterator, callback, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      :ok
    else
      value = Get.get(result, "value")
      invoke_or_close(iterator, callback, [value, index])
      for_each_loop(iterator, callback, index + 1)
    end
  end

  defp some_loop(iterator, predicate, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      false
    else
      value = Get.get(result, "value")
      keep = invoke_or_close(iterator, predicate, [value, index])

      if Values.truthy?(keep) do
        iterator_return(iterator)
        true
      else
        some_loop(iterator, predicate, index + 1)
      end
    end
  end

  defp reduce_without_initial(iterator, reducer) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      JSThrow.type_error!("Reduce of empty iterator with no initial value")
    else
      reduce_loop(iterator, reducer, Get.get(result, "value"), 1)
    end
  end

  defp reduce_loop(iterator, reducer, accumulator, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      accumulator
    else
      value = Get.get(result, "value")
      next_acc = invoke_or_close(iterator, reducer, [accumulator, value, index])
      reduce_loop(iterator, reducer, next_acc, index + 1)
    end
  end

  defp collect_values(iterator, acc) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      acc
    else
      collect_values(iterator, [Get.get(result, "value") | acc])
    end
  end

  defp every_loop(iterator, predicate, index) do
    result = iterator_next(iterator)

    if Get.get(result, "done") == true do
      true
    else
      value = Get.get(result, "value")
      keep = invoke_or_close(iterator, predicate, [value, index])

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
      keep = invoke_or_close(iterator, predicate, [value, index])

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

        if state["kind"] != :done do
          mark_helper_done(state_ref)

          cond do
            state["kind"] == :flat_map and state["inner"] != nil ->
              iterator_return(state["inner"])
              iterator_return(state["iterator"])

            state["iterator"] != nil ->
              iterator_return(state["iterator"])

            state["active"] != nil ->
              iterator_return(state["active"])

            true ->
              :ok
          end
        end

        iter_result(:undefined, true)

      _ ->
        JSThrow.type_error!("Iterator helper expected")
    end
  end

  defp helper_return(_), do: JSThrow.type_error!("Iterator helper expected")

  defp mark_helper_done(state_ref),
    do: Heap.put_obj(state_ref, %{"kind" => :done, "executing" => false})

  defp invoke_or_close(iterator, callback, args) do
    Invocation.invoke_with_receiver(callback, args, :undefined)
  catch
    {:js_throw, _} = reason ->
      close_record_preserving_reason(iterator)
      throw(reason)
  end

  defp close_record_preserving_reason(iterator) do
    try do
      iterator_return(iterator)
    catch
      {:js_throw, _} -> :ok
    end
  end

  defp close_and_type_error(this, message) do
    close_iterator_like(this)
    JSThrow.type_error!(message)
  end

  defp close_iterator_like(this) do
    if object_like?(this) do
      return_method = Get.get(this, "return")

      if Builtin.callable?(return_method) do
        Invocation.invoke_with_receiver(return_method, [], this)
      end
    end
  end

  defp iterator_record(this) do
    record = iterator_direct_record(this)

    unless Builtin.callable?(record["next"]),
      do: JSThrow.type_error!("Iterator next is not callable")

    record
  end

  defp iterator_direct_record(this) do
    unless object_like?(this), do: JSThrow.type_error!("Iterator receiver must be an object")

    next = Get.get(this, "next")

    if Builtin.callable?(next) do
      %{"iterator" => this, "next" => next}
    else
      nested_next = if object_like?(next), do: Get.get(next, "next"), else: :undefined

      if Builtin.callable?(nested_next) do
        %{"iterator" => next, "next" => nested_next}
      else
        %{"iterator" => this, "next" => next}
      end
    end
  end

  defp iterator_next(%{"iterator" => iterator, "next" => next}) do
    unless Builtin.callable?(next), do: JSThrow.type_error!("Iterator next is not callable")
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

  defp close_iterators_ignoring_errors(iterators) do
    iterators
    |> Enum.reverse()
    |> Enum.each(fn iterator ->
      try do
        iterator_return(iterator)
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  defp close_iterators_for_completion(iterators) do
    iterators
    |> Enum.reverse()
    |> Enum.reduce(nil, fn iterator, first_error ->
      try do
        iterator_return(iterator)
        first_error
      catch
        kind, reason -> first_error || {kind, reason, __STACKTRACE__}
      end
    end)
    |> case do
      nil -> :ok
      {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp iter_result(value, done) do
    Heap.wrap(%{
      "value" => value,
      "done" => done,
      "__proto__" => Heap.get_object_prototype(),
      key_order() => ["done", "value"]
    })
  end

  defp non_negative_integer_limit_or_close(this, value) do
    non_negative_integer_limit(value)
  catch
    {:js_throw, _} = reason ->
      close_iterator_like(this)
      throw(reason)
  end

  defp non_negative_integer_limit(:undefined), do: JSThrow.range_error!("invalid limit")

  defp non_negative_integer_limit(value) do
    number = Runtime.to_number(value)

    cond do
      number == :infinity -> :infinity
      number in [:nan, :neg_infinity] -> JSThrow.range_error!("invalid limit")
      not is_number(number) -> JSThrow.range_error!("invalid limit")
      trunc(number) < 0 -> JSThrow.range_error!("invalid limit")
      true -> trunc(number)
    end
  end

  defp wrapper_next(this) do
    {iterator, next} = wrapped_iterator_and_next!(this)
    unless Builtin.callable?(next), do: JSThrow.type_error!("Iterator next is not callable")
    result = Invocation.invoke_with_receiver(next, [], iterator)
    unless object_like?(result), do: JSThrow.type_error!("Iterator result is not an object")
    result
  end

  defp wrapper_return(this) do
    iterator = wrapped_iterator!(this)
    return_method = Get.get(iterator, "return")

    if Builtin.callable?(return_method) do
      Invocation.invoke_with_receiver(return_method, [], iterator)
    else
      Heap.wrap(%{"value" => :undefined, "done" => true})
    end
  end

  defp wrapped_iterator!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__wrapped_iterator__" => iterator} -> iterator
      _ -> JSThrow.type_error!("Iterator wrapper expected")
    end
  end

  defp wrapped_iterator!(_), do: JSThrow.type_error!("Iterator wrapper expected")

  defp wrapped_iterator_and_next!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__wrapped_iterator__" => iterator, "__wrapped_next__" => next} -> {iterator, next}
      _ -> JSThrow.type_error!("Iterator wrapper expected")
    end
  end

  defp wrapped_iterator_and_next!(_), do: JSThrow.type_error!("Iterator wrapper expected")

  defp object_like?({:obj, _}), do: true
  defp object_like?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp object_like?(%QuickBEAM.VM.Function{}), do: true
  defp object_like?({:builtin, _, _}), do: true
  defp object_like?({:bound, _, _, _, _}), do: true
  defp object_like?({:regexp, _, _}), do: true
  defp object_like?({:regexp, _, _, _}), do: true
  defp object_like?(_), do: false
end
