defmodule QuickBEAM.BeamVM.Runtime.MapSet do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime

  # ── Map/Set ──

  def weak_map_constructor do
    fn args, _this ->
      ref = make_ref()
      init = case args do
        [{:obj, _} = entries | _] ->
          Heap.to_list(entries)
          |> Enum.reduce(%{}, fn
            {:obj, eref}, acc ->
              case Heap.get_obj(eref, []) do
                [k, v | _] -> validate_weak_key!(k, "WeakMap"); Map.put(acc, k, v)
                _ -> acc
              end
            _, acc -> acc
          end)
        _ -> %{}
      end
      Heap.put_obj(ref, %{map_data() => init, "size" => map_size(init), :weak => true})
      {:obj, ref}
    end
  end

  def weak_set_constructor do
    fn args, _this ->
      ref = make_ref()
      items = case args do
        [source | _] ->
          Heap.to_list(source)
          |> Enum.each(&validate_weak_key!(&1, "WeakSet"))
          Heap.to_list(source)
        _ -> []
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

            if is_list(stored) do
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

    Heap.wrap(%{"next" => next_fn})
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
      {:obj, r} -> Map.get(Heap.get_obj(r, %{}), set_data(), [])
      _ -> []
    end
  end

  defp do_set_difference(set_ref, other) do
    set_constructor().([set_data(set_ref) -- other_set_data(other)], nil)
  end

  defp do_set_intersection(set_ref, other) do
    od = other_set_data(other)
    set_constructor().([Enum.filter(set_data(set_ref), &(&1 in od))], nil)
  end

  defp do_set_union(set_ref, other) do
    set_constructor().([Enum.uniq(set_data(set_ref) ++ other_set_data(other))], nil)
  end

  defp do_set_symmetric_difference(set_ref, other) do
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
    Enum.all?(other_set_data(other), &(&1 in d))
  end

  defp do_set_is_disjoint(set_ref, other) do
    od = other_set_data(other)
    not Enum.any?(set_data(set_ref), &(&1 in od))
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
  def map_proto("size"), do: {:builtin, "size", fn _, {:obj, ref} ->
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
    new_data = Map.put(data, key, val)

    Heap.put_obj(ref, %{
      obj
      | map_data() => new_data,
        "size" => map_size(new_data)
    })

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

    Heap.put_obj(ref, %{
      obj
      | map_data() => new_data,
        "size" => map_size(new_data)
    })

    true
  end

  defp map_clear(_, {:obj, ref}) do
    obj = Heap.get_obj(ref, %{})
    Heap.put_obj(ref, %{obj | map_data() => %{}, "size" => 0})
    :undefined
  end

  defp map_keys(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Heap.wrap(Map.keys(data))
  end

  defp map_values(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    Heap.wrap(Map.values(data))
  end

  defp map_entries(_, {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})
    entries = Enum.map(data, fn {k, v} -> Heap.wrap([k, v]) end)
    Heap.wrap(entries)
  end

  defp map_for_each([cb | _], {:obj, ref}) do
    data = Heap.get_obj(ref, %{}) |> Map.get(map_data(), %{})

    Enum.each(data, fn {k, v} ->
      Runtime.call_callback(cb, [v, k, {:obj, ref}])
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
