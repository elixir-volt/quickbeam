defmodule QuickBEAM.BeamVM.Runtime.MapSet do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.ObjectModel.Get
  alias QuickBEAM.BeamVM.Runtime

  # ── Map/Set ──

  def weak_map_constructor do
    fn args, _this ->
      ref = make_ref()

      init =
        case args do
          [{:obj, _} = entries | _] ->
            Heap.to_list(entries)
            |> Enum.reduce(%{}, fn
              {:obj, eref}, acc ->
                case Heap.get_obj(eref, []) do
                  [k, v | _] ->
                    validate_weak_key!(k, "WeakMap")
                    Map.put(acc, k, v)

                  _ ->
                    acc
                end

              _, acc ->
                acc
            end)

          _ ->
            %{}
        end

      Heap.put_obj(ref, %{map_data() => init, "size" => map_size(init), :weak => true})
      {:obj, ref}
    end
  end

  def weak_set_constructor do
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

  defp validate_weak_key!({:obj, _}, _), do: :ok
  defp validate_weak_key!({:symbol, _, _}, _), do: :ok

  defp validate_weak_key!(_, kind),
    do: throw({:js_throw, Heap.make_error("invalid value used as #{kind} key", "TypeError")})

  def map_constructor do
    fn args, _this ->
      ref = make_ref()

      entries =
        case args do
          [list] when is_list(list) ->
            Map.new(list, fn [k, v] -> {k, v} end)

          [{:obj, r}] ->
            stored = Heap.get_obj(r, [])

            if is_list(stored) or match?({:qb_arr, _}, stored) do
              Map.new(stored, fn
                [k, v] ->
                  {k, v}

                {:obj, eref} ->
                  case Heap.get_obj(eref, []) do
                    [k, v | _] -> {k, v}
                    _ -> {nil, nil}
                  end

                _ ->
                  {nil, nil}
              end)
            else
              %{}
            end

          _ ->
            %{}
        end

      map_obj = %{
        map_data() => entries,
        "size" => map_size(entries)
      }

      Heap.put_obj(ref, map_obj)
      {:obj, ref}
    end
  end

  def set_constructor do
    fn args, _this ->
      ref = make_ref()
      items = Heap.to_list(List.first(args)) |> Enum.uniq()

      set_obj = build_set_object(ref, items)
      Heap.put_obj(ref, set_obj)
      {:obj, ref}
    end
  end

  defp build_set_object(set_ref, items) do
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

  defp set_data(set_ref),
    do: Map.get(Heap.get_obj(set_ref, %{}), set_data(), [])

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
           val = Enum.at(list, state.pos)
           Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
           Heap.wrap(%{"value" => val, "done" => false})
         end
       end}

    build_object do
      val("next", next_fn)
    end
  end

  defp do_set_entries(set_ref) do
    data = set_data(set_ref)
    pairs = Enum.map(data, fn v -> Heap.wrap([v, v]) end)
    Heap.wrap(pairs)
  end

  defp do_set_add(set_ref, val) do
    data = set_data(set_ref)
    unless val in data, do: set_update_data(set_ref, data ++ [val])
    {:obj, set_ref}
  end

  defp do_set_delete(set_ref, val) do
    data = set_data(set_ref)
    set_update_data(set_ref, List.delete(data, val))
    val in data
  end

  defp do_set_foreach(set_ref, cb) do
    for v <- set_data(set_ref) do
      Runtime.call_callback(cb, [v, v])
    end

    :undefined
  end

  defp other_set_data(other) do
    case other do
      {:obj, r} ->
        map = Heap.get_obj(r, %{})

        case Map.get(map, set_data()) do
          items when is_list(items) ->
            items

          _ ->
            keys_fn = Get.get(other, "keys")
            iterate_setlike(keys_fn, other)
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

  defp other_set_has(other, val) do
    has_fn = Get.get(other, "has")

    case has_fn do
      {:builtin, _, f} when is_function(f) -> f.([val], other) == true
      f -> Runtime.call_callback(f, [val]) == true
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

    done = Get.get(result, "done")

    if done == true do
      Enum.reverse(acc)
    else
      value = Get.get(result, "value")
      collect_iterator(iterator, [value | acc])
    end
  end

  defp call_with_this(fun, args, this) do
    case fun do
      {:builtin, _, f} when is_function(f) ->
        f.(args, this)

      %Bytecode.Function{} = f ->
        Interpreter.invoke_with_receiver(f, args, Runtime.gas_budget(), this)

      {:closure, _, %Bytecode.Function{}} = c ->
        Interpreter.invoke_with_receiver(c, args, Runtime.gas_budget(), this)

      _ ->
        Runtime.call_callback(fun, args)
    end
  end

  defp do_set_difference(set_ref, other) do
    validate_set_like!(other)
    set_constructor().([set_data(set_ref) -- other_set_data(other)], nil)
  end

  defp do_set_intersection(set_ref, other) do
    validate_set_like!(other)
    od = other_set_data(other)
    set_constructor().([Enum.filter(set_data(set_ref), &(&1 in od))], nil)
  end

  defp do_set_union(set_ref, other) do
    validate_set_like!(other)
    set_constructor().([Enum.uniq(set_data(set_ref) ++ other_set_data(other))], nil)
  end

  defp do_set_symmetric_difference(set_ref, other) do
    validate_set_like!(other)
    d = set_data(set_ref)
    od = other_set_data(other)
    set_constructor().([(d -- od) ++ (od -- d)], nil)
  end

  defp do_set_is_subset(set_ref, other) do
    od = other_set_data(other)
    Enum.all?(set_data(set_ref), &(&1 in od))
  end

  defp do_set_is_superset(set_ref, other) do
    d = set_data(set_ref)
    other_size = other_set_size(other)

    if is_number(other_size) and length(d) >= other_size do
      keys_fn = Get.get(other, "keys")
      iterator = call_with_this(keys_fn, [], other)
      iterate_check_all(iterator, d, other)
    else
      false
    end
  end

  defp do_set_is_disjoint(set_ref, other) do
    d = set_data(set_ref)
    other_size = other_set_size(other)

    if is_number(other_size) and length(d) > other_size do
      keys_fn = Get.get(other, "keys")
      iterator = call_with_this(keys_fn, [], other)
      iterate_check_none(iterator, d, other)
    else
      not Enum.any?(d, fn v -> other_set_has(other, v) end)
    end
  end

  defp iterate_check_all(iterator, set_data, _other) do
    next_fn = Get.get(iterator, "next")
    do_iterate_check(iterator, next_fn, set_data, :all)
  end

  defp iterate_check_none(iterator, set_data, _other) do
    next_fn = Get.get(iterator, "next")
    do_iterate_check(iterator, next_fn, set_data, :none)
  end

  defp do_iterate_check(iterator, next_fn, set_data, mode) do
    result = call_with_this(next_fn, [], iterator)
    done = Get.get(result, "done")

    if done == true do
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

  # ── Map prototype (property resolution) ──

  defp normalize_map_key(k) when is_float(k) and k == trunc(k), do: trunc(k)
  defp normalize_map_key(k), do: k

  # ── Map prototype ──

  def map_proto("get"), do: {:builtin, "get", &map_get/2}
  def map_proto("set"), do: {:builtin, "set", &map_set/2}
  def map_proto("has"), do: {:builtin, "has", &map_has/2}
  def map_proto("delete"), do: {:builtin, "delete", &map_delete/2}
  def map_proto("clear"), do: {:builtin, "clear", &map_clear/2}
  def map_proto("keys"), do: {:builtin, "keys", &map_keys/2}
  def map_proto("values"), do: {:builtin, "values", &map_values/2}
  def map_proto("entries"), do: {:builtin, "entries", &map_entries/2}
  def map_proto("forEach"), do: {:builtin, "forEach", &map_for_each/2}

  def map_proto("size"),
    do:
      {:builtin, "size",
       fn _, {:obj, ref} ->
         Map.get(Heap.get_obj(ref, %{}), map_data(), %{}) |> map_size()
       end}

  def map_proto(_), do: :undefined

  defp map_get([key | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.get(data, normalize_map_key(key), :undefined)
  end

  defp map_set([key, val | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: validate_weak_key!(key, "WeakMap")
    key = normalize_map_key(key)
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), [])
    order = if Map.has_key?(data, key), do: order, else: [key | order]
    new_data = Map.put(data, key, val)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{
        map_data() => new_data,
        "size" => map_size(new_data),
        key_order() => order
      })
    )

    {:obj, ref}
  end

  defp map_has([key | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Map.has_key?(data, normalize_map_key(key))
  end

  defp map_delete([key | _], {:obj, ref}) do
    key = normalize_map_key(key)
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    new_data = Map.delete(data, key)
    order = Map.get(obj, key_order(), []) |> List.delete(key)

    Heap.put_obj(
      ref,
      Map.merge(obj, %{
        map_data() => new_data,
        "size" => map_size(new_data),
        key_order() => order
      })
    )

    true
  end

  defp map_clear(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | map_data() => %{}, "size" => 0})
    :undefined
  end

  defp map_keys(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()
    Heap.wrap(order)
  end

  defp map_values(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()
    Heap.wrap(Enum.map(order, &Map.get(data, &1)))
  end

  defp map_entries(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()
    entries = Enum.map(order, fn k -> Heap.wrap([k, Map.get(data, k)]) end)
    Heap.wrap(entries)
  end

  defp map_for_each([cb | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, map_data(), %{})
    order = Map.get(obj, key_order(), []) |> Enum.reverse()

    Enum.each(order, fn k ->
      case Map.fetch(data, k) do
        {:ok, v} -> Runtime.call_callback(cb, [v, k, {:obj, ref}])
        :error -> :ok
      end
    end)

    :undefined
  end

  # ── Set prototype ──

  def set_proto("has"), do: {:builtin, "has", &set_has/2}
  def set_proto("add"), do: {:builtin, "add", &set_add/2}
  def set_proto("delete"), do: {:builtin, "delete", &set_delete/2}
  def set_proto("clear"), do: {:builtin, "clear", &set_clear/2}
  def set_proto("values"), do: {:builtin, "values", &set_values/2}
  def set_proto("keys"), do: set_proto("values")
  def set_proto("entries"), do: {:builtin, "entries", &set_entries/2}
  def set_proto("forEach"), do: {:builtin, "forEach", &set_for_each/2}
  def set_proto(_), do: :undefined

  defp set_has([val | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    val in data
  end

  defp set_add([val | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    if Map.get(obj, :weak), do: validate_weak_key!(val, "WeakSet")
    data = Map.get(obj, set_data(), [])

    unless val in data do
      new_data = data ++ [val]

      Heap.put_obj(ref, %{
        obj
        | set_data() => new_data,
          "size" => length(new_data)
      })
    end

    {:obj, ref}
  end

  defp set_delete([val | _], {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    data = Map.get(obj, set_data(), [])
    new_data = List.delete(data, val)

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
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    Heap.wrap(data)
  end

  defp set_entries(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])
    entries = Enum.map(data, fn v -> Heap.wrap([v, v]) end)
    Heap.wrap(entries)
  end

  defp set_for_each([cb | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(set_data(), [])

    Enum.each(data, fn v ->
      Runtime.call_callback(cb, [v, v, {:obj, ref}])
    end)

    :undefined
  end
end
