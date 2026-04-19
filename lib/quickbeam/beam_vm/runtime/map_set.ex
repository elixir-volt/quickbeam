defmodule QuickBEAM.BeamVM.Runtime.MapSet do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Heap

  # ── Map/Set ──

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
           Heap.iter_result(:undefined, true)
         else
           val = Enum.at(list, state.pos)
           Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
           Heap.iter_result(val, false)
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
      QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [v, v], :no_interp)
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
    set_constructor().([set_data(set_ref) -- other_set_data(other)])
  end

  defp do_set_intersection(set_ref, other) do
    od = other_set_data(other)
    set_constructor().([Enum.filter(set_data(set_ref), &(&1 in od))])
  end

  defp do_set_union(set_ref, other) do
    set_constructor().([Enum.uniq(set_data(set_ref) ++ other_set_data(other))])
  end

  defp do_set_symmetric_difference(set_ref, other) do
    d = set_data(set_ref)
    od = other_set_data(other)
    set_constructor().([(d -- od) ++ (od -- d)])
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
end
