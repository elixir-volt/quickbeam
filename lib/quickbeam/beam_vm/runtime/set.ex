defmodule QuickBEAM.BeamVM.Runtime.Set do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.ObjectModel.Get
  alias QuickBEAM.BeamVM.Runtime

  def constructor do
    fn args, _this ->
      ref = make_ref()
      items = Heap.to_list(List.first(args)) |> Enum.uniq()
      Heap.put_obj(ref, build_object(ref, items))
      {:obj, ref}
    end
  end

  def weak_constructor do
    fn args, _this ->
      ref = make_ref()

      items =
        case args do
          [source | _] ->
            Heap.to_list(source)
            |> Enum.each(&validate_weak_key!(&1, "WeakSet"))

            Heap.to_list(source)

          _ ->
            []
        end

      Heap.put_obj(ref, %{set_data() => items, "size" => length(items), :weak => true})
      {:obj, ref}
    end
  end

  def proto_property("has"), do: {:builtin, "has", &set_has/2}
  def proto_property("add"), do: {:builtin, "add", &set_add/2}
  def proto_property("delete"), do: {:builtin, "delete", &set_delete/2}
  def proto_property("clear"), do: {:builtin, "clear", &set_clear/2}
  def proto_property("values"), do: {:builtin, "values", &set_values/2}
  def proto_property("keys"), do: proto_property("values")
  def proto_property("entries"), do: {:builtin, "entries", &set_entries/2}
  def proto_property("forEach"), do: {:builtin, "forEach", &set_for_each/2}
  def proto_property(_), do: :undefined

  defp validate_weak_key!({:obj, _}, _), do: :ok
  defp validate_weak_key!({:symbol, _, _}, _), do: :ok

  defp validate_weak_key!(_, kind) do
    throw({:js_throw, Heap.make_error("invalid value used as #{kind} key", "TypeError")})
  end

  defp build_object(set_ref, items) do
    methods =
      build_methods do
        method "values" do
          do_set_values(set_ref)
        end

        method "keys" do
          do_set_values(set_ref)
        end

        method "entries" do
          do_set_entries(set_ref)
        end

        method "add" do
          do_set_add(set_ref, hd(args))
        end

        method "delete" do
          do_set_delete(set_ref, hd(args))
        end

        method "clear" do
          set_update_data(set_ref, [])
          :undefined
        end

        method "has" do
          hd(args) in set_data(set_ref)
        end

        method "forEach" do
          do_set_foreach(set_ref, hd(args))
        end

        method "difference" do
          do_set_difference(set_ref, hd(args))
        end

        method "intersection" do
          do_set_intersection(set_ref, hd(args))
        end

        method "union" do
          do_set_union(set_ref, hd(args))
        end

        method "symmetricDifference" do
          do_set_symmetric_difference(set_ref, hd(args))
        end

        method "isSubsetOf" do
          do_set_is_subset(set_ref, hd(args))
        end

        method "isSupersetOf" do
          do_set_is_superset(set_ref, hd(args))
        end

        method "isDisjointFrom" do
          do_set_is_disjoint(set_ref, hd(args))
        end

        val(set_data(), items)
        val("size", length(items))
      end

    Map.put(methods, {:symbol, "Symbol.iterator"}, methods["values"])
  end

  defp set_data(set_ref), do: Heap.get_obj(set_ref, %{}) |> Map.get(set_data(), [])

  defp set_update_data(set_ref, new_data) do
    map = Heap.get_obj(set_ref, %{})

    Heap.put_obj(set_ref, %{
      map
      | set_data() => new_data,
        "size" => length(new_data)
    })
  end

  defp do_set_values(set_ref) do
    data = set_data(set_ref)
    pos_ref = make_ref()
    Heap.put_obj(pos_ref, %{pos: 0, list: data})

    next_fn =
      {:builtin, "next",
       fn _, _ ->
         state = Heap.get_obj(pos_ref, %{pos: 0, list: []})
         list = if is_list(state.list), do: state.list, else: []

         if state.pos >= length(list) do
           Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
           Heap.wrap(%{"value" => :undefined, "done" => true})
         else
           value = Enum.at(list, state.pos)
           Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
           Heap.wrap(%{"value" => value, "done" => false})
         end
       end}

    build_object do
      val("next", next_fn)
    end
  end

  defp do_set_entries(set_ref) do
    set_ref
    |> set_data()
    |> Enum.map(fn value -> Heap.wrap([value, value]) end)
    |> Heap.wrap()
  end

  defp do_set_add(set_ref, value) do
    data = set_data(set_ref)
    unless value in data, do: set_update_data(set_ref, data ++ [value])
    {:obj, set_ref}
  end

  defp do_set_delete(set_ref, value) do
    data = set_data(set_ref)
    set_update_data(set_ref, List.delete(data, value))
    value in data
  end

  defp do_set_foreach(set_ref, callback) do
    for value <- set_data(set_ref) do
      Runtime.call_callback(callback, [value, value])
    end

    :undefined
  end

  defp other_set_data(other) do
    case other do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        case Map.get(map, set_data()) do
          items when is_list(items) ->
            items

          _ ->
            other
            |> Get.get("keys")
            |> iterate_setlike(other)
        end

      _ ->
        []
    end
  end

  defp other_set_size(other) do
    case other do
      {:obj, _} -> Get.get(other, "size")
      _ -> 0
    end
  end

  defp validate_set_like!(other) do
    size = other_set_size(other)

    cond do
      size == :nan or size == :NaN ->
        throw({:js_throw, Heap.make_error("can't convert to number: .size is NaN", "TypeError")})

      is_number(size) and size < 0 ->
        throw({:js_throw, Heap.make_error("invalid .size: must be non-negative", "RangeError")})

      size == :neg_infinity ->
        throw({:js_throw, Heap.make_error("invalid .size: must be non-negative", "RangeError")})

      true ->
        :ok
    end
  end

  defp other_set_has(other, value) do
    has_fn = Get.get(other, "has")

    case has_fn do
      {:builtin, _, fun} when is_function(fun) -> fun.([value], other) == true
      fun -> Runtime.call_callback(fun, [value]) == true
    end
  end

  defp iterate_setlike(keys_fn, _other) when keys_fn in [:undefined, nil], do: []

  defp iterate_setlike(keys_fn, other) do
    iterator = call_with_this(keys_fn, [], other)
    collect_iterator(iterator, [])
  end

  defp collect_iterator(iterator, acc) do
    next_fn = Get.get(iterator, "next")
    result = call_with_this(next_fn, [], iterator)

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      value = Get.get(result, "value")
      collect_iterator(iterator, [value | acc])
    end
  end

  defp call_with_this(fun, args, this) do
    case fun do
      {:builtin, _, callback} when is_function(callback) ->
        callback.(args, this)

      %Bytecode.Function{} = function ->
        Interpreter.invoke_with_receiver(function, args, Runtime.gas_budget(), this)

      {:closure, _, %Bytecode.Function{}} = closure ->
        Interpreter.invoke_with_receiver(closure, args, Runtime.gas_budget(), this)

      _ ->
        Runtime.call_callback(fun, args)
    end
  end

  defp do_set_difference(set_ref, other) do
    validate_set_like!(other)
    constructor().([set_data(set_ref) -- other_set_data(other)], nil)
  end

  defp do_set_intersection(set_ref, other) do
    validate_set_like!(other)
    other_data = other_set_data(other)
    constructor().([Enum.filter(set_data(set_ref), &(&1 in other_data))], nil)
  end

  defp do_set_union(set_ref, other) do
    validate_set_like!(other)
    constructor().([Enum.uniq(set_data(set_ref) ++ other_set_data(other))], nil)
  end

  defp do_set_symmetric_difference(set_ref, other) do
    validate_set_like!(other)
    data = set_data(set_ref)
    other_data = other_set_data(other)
    constructor().([(data -- other_data) ++ (other_data -- data)], nil)
  end

  defp do_set_is_subset(set_ref, other) do
    other_data = other_set_data(other)
    Enum.all?(set_data(set_ref), &(&1 in other_data))
  end

  defp do_set_is_superset(set_ref, other) do
    data = set_data(set_ref)
    other_size = other_set_size(other)

    if is_number(other_size) and length(data) >= other_size do
      iterator = other |> Get.get("keys") |> call_with_this([], other)
      iterate_check_all(iterator, data)
    else
      false
    end
  end

  defp do_set_is_disjoint(set_ref, other) do
    data = set_data(set_ref)
    other_size = other_set_size(other)

    if is_number(other_size) and length(data) > other_size do
      iterator = other |> Get.get("keys") |> call_with_this([], other)
      iterate_check_none(iterator, data)
    else
      not Enum.any?(data, fn value -> other_set_has(other, value) end)
    end
  end

  defp iterate_check_all(iterator, set_data) do
    next_fn = Get.get(iterator, "next")
    do_iterate_check(iterator, next_fn, set_data, :all)
  end

  defp iterate_check_none(iterator, set_data) do
    next_fn = Get.get(iterator, "next")
    do_iterate_check(iterator, next_fn, set_data, :none)
  end

  defp do_iterate_check(iterator, next_fn, set_data, mode) do
    result = call_with_this(next_fn, [], iterator)

    if Get.get(result, "done") == true do
      true
    else
      value = Get.get(result, "value")
      in_set = value in set_data

      case mode do
        :all ->
          if in_set do
            do_iterate_check(iterator, next_fn, set_data, mode)
          else
            call_iterator_return(iterator)
            false
          end

        :none ->
          if in_set do
            call_iterator_return(iterator)
            false
          else
            do_iterate_check(iterator, next_fn, set_data, mode)
          end
      end
    end
  end

  defp call_iterator_return(iterator) do
    return_fn = Get.get(iterator, "return")

    if return_fn != :undefined and return_fn != nil do
      call_with_this(return_fn, [], iterator)
    end
  end

  defp set_has([value | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    value in data
  end

  defp set_add([value | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: validate_weak_key!(value, "WeakSet")
    data = Map.get(obj, set_data(), [])

    unless value in data do
      new_data = data ++ [value]

      Heap.put_obj(ref, %{
        obj
        | set_data() => new_data,
          "size" => length(new_data)
      })
    end

    {:obj, ref}
  end

  defp set_delete([value | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, set_data(), [])
    new_data = List.delete(data, value)

    Heap.put_obj(ref, %{
      obj
      | set_data() => new_data,
        "size" => length(new_data)
    })

    true
  end

  defp set_clear(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | set_data() => [], "size" => 0})
    :undefined
  end

  defp set_values(_, {:obj, ref}) do
    ref
    |> Heap.get_obj(%{})
    |> Map.get(set_data(), [])
    |> Heap.wrap()
  end

  defp set_entries(_, {:obj, ref}) do
    ref
    |> Heap.get_obj(%{})
    |> Map.get(set_data(), [])
    |> Enum.map(fn value -> Heap.wrap([value, value]) end)
    |> Heap.wrap()
  end

  defp set_for_each([callback | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])

    Enum.each(data, fn value ->
      Runtime.call_callback(callback, [value, value, {:obj, ref}])
    end)

    :undefined
  end
end
