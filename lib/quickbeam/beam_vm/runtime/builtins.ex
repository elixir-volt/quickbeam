defmodule QuickBEAM.BeamVM.Runtime.Builtins do
  import QuickBEAM.BeamVM.Heap.Keys
  alias QuickBEAM.BeamVM.Heap
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime

  # ── Boolean.prototype ──

  def boolean_proto_property("toString"),
    do: {:builtin, "toString", fn _args, this -> Atom.to_string(this) end}

  def boolean_proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}
  def boolean_proto_property(_), do: :undefined

  # ── Constructors ──

  def object_constructor, do: fn _args -> Runtime.obj_new() end

  def array_constructor do
    fn args ->
      list =
        case args do
          [n] when is_integer(n) and n >= 0 -> List.duplicate(:undefined, n)
          _ -> args
        end

      Heap.wrap(list)
    end
  end

  def string_constructor, do: fn args -> Runtime.js_to_string(List.first(args, "")) end
  def number_constructor, do: fn args -> Runtime.to_number(List.first(args, 0)) end
  def boolean_constructor, do: fn args -> Runtime.js_truthy(List.first(args, false)) end

  def function_constructor do
    fn _args ->
      throw(
        {:js_throw,
         %{"message" => "Function constructor not supported in BEAM mode", "name" => "Error"}}
      )
    end
  end

  def bigint_constructor do
    fn
      [n | _] when is_integer(n) ->
        {:bigint, n}

      [s | _] when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} ->
            {:bigint, n}

          _ ->
            throw(
              {:js_throw, %{"message" => "Cannot convert to BigInt", "name" => "SyntaxError"}}
            )
        end

      [{:bigint, n} | _] ->
        {:bigint, n}

      _ ->
        throw({:js_throw, %{"message" => "Cannot convert to BigInt", "name" => "TypeError"}})
    end
  end

  def error_constructor do
    fn args ->
      msg = List.first(args, "")
      Heap.wrap(%{"message" => Runtime.js_to_string(msg), "stack" => ""})
    end
  end

  def date_static_property("UTC") do
    {:builtin, "UTC",
     fn args ->
       [y, m | rest] = args ++ List.duplicate(0, 7)
       d = Enum.at(rest, 0, 1)
       h = Enum.at(rest, 1, 0)
       min = Enum.at(rest, 2, 0)
       s = Enum.at(rest, 3, 0)
       ms = Enum.at(rest, 4, 0)
       year = if is_number(y) and y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y || 0)

       case NaiveDateTime.new(
              year,
              trunc(m || 0) + 1,
              max(1, trunc(d)),
              trunc(h),
              trunc(min),
              trunc(s)
            ) do
         {:ok, dt} ->
           DateTime.from_naive!(dt, "Etc/UTC")
           |> DateTime.to_unix(:millisecond)
           |> Kernel.+(trunc(ms))

         _ ->
           :nan
       end
     end}
  end

  def date_static_property("now") do
    {:builtin, "now", fn _ -> System.system_time(:millisecond) end}
  end

  def date_static_property(_), do: :undefined

  def date_constructor do
    fn args ->
      ms =
        case args do
          [] ->
            System.system_time(:millisecond)

          [n | _] when is_number(n) ->
            n

          [s | _] when is_binary(s) ->
            case DateTime.from_iso8601(s) do
              {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
              _ -> :nan
            end

          _ ->
            :nan
        end

      Heap.wrap(%{"valueOf" => ms})
    end
  end

  def promise_constructor do
    fn _args ->
      Heap.wrap(%{})
    end
  end

  def promise_statics do
    %{
      "resolve" =>
        {:builtin, "resolve",
         fn
           [val | _] -> QuickBEAM.BeamVM.Interpreter.make_resolved_promise(val)
           [] -> QuickBEAM.BeamVM.Interpreter.make_resolved_promise(:undefined)
         end},
      "reject" =>
        {:builtin, "reject",
         fn [val | _] ->
           QuickBEAM.BeamVM.Interpreter.make_rejected_promise(val)
         end},
      "all" =>
        {:builtin, "all",
         fn [arr | _] ->
           items =
             case arr do
               {:obj, ref} ->
                 case QuickBEAM.BeamVM.Heap.get_obj(ref, []) do
                   list when is_list(list) -> list
                   _ -> []
                 end

               list when is_list(list) ->
                 list

               _ ->
                 []
             end

           results =
             Enum.map(items, fn item ->
               case item do
                 {:obj, r} ->
                   case QuickBEAM.BeamVM.Heap.get_obj(r, %{}) do
                     %{
                       promise_state() => :resolved,
                       promise_value() => val
                     } ->
                       val

                     _ ->
                       item
                   end

                 _ ->
                   item
               end
             end)

           result_ref = make_ref()
           QuickBEAM.BeamVM.Heap.put_obj(result_ref, results)
           QuickBEAM.BeamVM.Interpreter.make_resolved_promise({:obj, result_ref})
         end},
      "allSettled" =>
        {:builtin, "allSettled",
         fn [arr | _] ->
           items =
             case arr do
               {:obj, ref} ->
                 case Heap.get_obj(ref, []) do
                   list when is_list(list) -> list
                   _ -> []
                 end

               _ ->
                 []
             end

           results =
             Enum.map(items, fn item ->
               {status, val} =
                 case item do
                   {:obj, r} ->
                     case Heap.get_obj(r, %{}) do
                       %{
                         promise_state() => :resolved,
                         promise_value() => v
                       } ->
                         {"fulfilled", v}

                       %{
                         promise_state() => :rejected,
                         promise_value() => v
                       } ->
                         {"rejected", v}

                       _ ->
                         {"fulfilled", item}
                     end

                   _ ->
                     {"fulfilled", item}
                 end

               r = make_ref()

               m =
                 if status == "fulfilled",
                   do: %{"status" => status, "value" => val},
                   else: %{"status" => status, "reason" => val}

               Heap.put_obj(r, m)
               {:obj, r}
             end)

           result_ref = make_ref()
           Heap.put_obj(result_ref, results)
           QuickBEAM.BeamVM.Interpreter.make_resolved_promise({:obj, result_ref})
         end},
      "any" =>
        {:builtin, "any",
         fn [arr | _] ->
           items =
             case arr do
               {:obj, ref} ->
                 case Heap.get_obj(ref, []) do
                   list when is_list(list) -> list
                   _ -> []
                 end

               _ ->
                 []
             end

           result =
             Enum.find_value(items, fn item ->
               case item do
                 {:obj, r} ->
                   case Heap.get_obj(r, %{}) do
                     %{
                       promise_state() => :resolved,
                       promise_value() => v
                     } ->
                       v

                     _ ->
                       nil
                   end

                 _ ->
                   item
               end
             end)

           QuickBEAM.BeamVM.Interpreter.make_resolved_promise(result || :undefined)
         end},
      "race" =>
        {:builtin, "race",
         fn [arr | _] ->
           items =
             case arr do
               {:obj, ref} ->
                 case QuickBEAM.BeamVM.Heap.get_obj(ref, []) do
                   list when is_list(list) -> list
                   _ -> []
                 end

               _ ->
                 []
             end

           case items do
             [first | _] ->
               val =
                 case first do
                   {:obj, r} ->
                     case QuickBEAM.BeamVM.Heap.get_obj(r, %{}) do
                       %{
                         promise_state() => :resolved,
                         promise_value() => v
                       } ->
                         v

                       _ ->
                         first
                     end

                   _ ->
                     first
                 end

               QuickBEAM.BeamVM.Interpreter.make_resolved_promise(val)

             [] ->
               QuickBEAM.BeamVM.Interpreter.make_resolved_promise(:undefined)
           end
         end}
    }
  end

  def regexp_constructor do
    fn [pattern | rest] ->
      flags =
        case rest do
          [f | _] when is_binary(f) -> f
          _ -> ""
        end

      pat =
        case pattern do
          {:regexp, p, _} -> p
          s when is_binary(s) -> s
          _ -> ""
        end

      {:regexp, pat, flags}
    end
  end

  def symbol_constructor do
    fn args ->
      desc =
        case args do
          [s | _] when is_binary(s) -> s
          _ -> ""
        end

      {:symbol, desc, make_ref()}
    end
  end

  def symbol_statics do
    %{
      "iterator" => {:symbol, "Symbol.iterator"},
      "toPrimitive" => {:symbol, "Symbol.toPrimitive"},
      "hasInstance" => {:symbol, "Symbol.hasInstance"},
      "toStringTag" => {:symbol, "Symbol.toStringTag"},
      "asyncIterator" => {:symbol, "Symbol.asyncIterator"},
      "isConcatSpreadable" => {:symbol, "Symbol.isConcatSpreadable"},
      "species" => {:symbol, "Symbol.species"},
      "match" => {:symbol, "Symbol.match"},
      "replace" => {:symbol, "Symbol.replace"},
      "search" => {:symbol, "Symbol.search"},
      "split" => {:symbol, "Symbol.split"},
      "for" =>
        {:builtin, "for",
         fn [key | _] ->
           case Heap.get_symbol(key) do
             nil ->
               sym = {:symbol, key}
               Heap.put_symbol(key, sym)
               sym

             existing ->
               existing
           end
         end},
      "keyFor" =>
        {:builtin, "keyFor",
         fn [sym | _] ->
           case sym do
             {:symbol, key} -> key
             {:symbol, key, _ref} -> key
             _ -> :undefined
           end
         end}
    }
  end

  # ── Global functions ──

  # ── Map/Set ──

  def map_constructor do
    fn args ->
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
    fn args ->
      ref = make_ref()
      items = Heap.to_list(List.first(args)) |> Enum.uniq()

      set_obj = build_set_object(ref, items)
      Heap.put_obj(ref, set_obj)
      {:obj, ref}
    end
  end

  defp build_set_object(set_ref, items) do
    %{
      set_data() => items,
      "size" => length(items),
      {:symbol, "Symbol.iterator"} => set_values_fn(set_ref),
      "values" => set_values_fn(set_ref),
      "keys" => set_values_fn(set_ref),
      "entries" => set_entries_fn(set_ref),
      "add" => set_add_fn(set_ref),
      "delete" => set_delete_fn(set_ref),
      "clear" => set_clear_fn(set_ref),
      "has" => set_has_fn(set_ref),
      "forEach" => set_foreach_fn(set_ref),
      "difference" => set_difference_fn(set_ref),
      "intersection" => set_intersection_fn(set_ref),
      "union" => set_union_fn(set_ref),
      "symmetricDifference" => set_symmetric_difference_fn(set_ref),
      "isSubsetOf" => set_is_subset_fn(set_ref),
      "isSupersetOf" => set_is_superset_fn(set_ref),
      "isDisjointFrom" => set_is_disjoint_fn(set_ref)
    }
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

  defp set_values_fn(set_ref) do
    {:builtin, "values",
     fn _, _ ->
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
     end}
  end

  defp set_entries_fn(set_ref) do
    {:builtin, "entries",
     fn _, _ ->
       data = set_data(set_ref)
       pairs = Enum.map(data, fn v -> Heap.wrap([v, v]) end)
       Heap.wrap(pairs)
     end}
  end

  defp set_add_fn(set_ref) do
    {:builtin, "add",
     fn [val | _], _ ->
       data = set_data(set_ref)
       unless val in data, do: set_update_data(set_ref, data ++ [val])
       {:obj, set_ref}
     end}
  end

  defp set_delete_fn(set_ref) do
    {:builtin, "delete",
     fn [val | _], _ ->
       data = set_data(set_ref)
       set_update_data(set_ref, List.delete(data, val))
       val in data
     end}
  end

  defp set_clear_fn(set_ref) do
    {:builtin, "clear",
     fn _, _ ->
       set_update_data(set_ref, [])
       :undefined
     end}
  end

  defp set_has_fn(set_ref) do
    {:builtin, "has", fn [val | _], _ -> val in set_data(set_ref) end}
  end

  defp set_foreach_fn(set_ref) do
    {:builtin, "forEach",
     fn [cb | _], _ ->
       for v <- set_data(set_ref) do
         QuickBEAM.BeamVM.Runtime.call_builtin_callback(cb, [v, v], :no_interp)
       end

       :undefined
     end}
  end

  defp other_set_data(other) do
    case other do
      {:obj, r} -> Map.get(Heap.get_obj(r, %{}), set_data(), [])
      _ -> []
    end
  end

  defp set_difference_fn(set_ref) do
    {:builtin, "difference",
     fn [other | _], _ ->
       set_constructor().([set_data(set_ref) -- other_set_data(other)])
     end}
  end

  defp set_intersection_fn(set_ref) do
    {:builtin, "intersection",
     fn [other | _], _ ->
       od = other_set_data(other)
       set_constructor().([Enum.filter(set_data(set_ref), &(&1 in od))])
     end}
  end

  defp set_union_fn(set_ref) do
    {:builtin, "union",
     fn [other | _], _ ->
       set_constructor().([Enum.uniq(set_data(set_ref) ++ other_set_data(other))])
     end}
  end

  defp set_symmetric_difference_fn(set_ref) do
    {:builtin, "symmetricDifference",
     fn [other | _], _ ->
       d = set_data(set_ref)
       od = other_set_data(other)
       set_constructor().([(d -- od) ++ (od -- d)])
     end}
  end

  defp set_is_subset_fn(set_ref) do
    {:builtin, "isSubsetOf",
     fn [other | _], _ ->
       od = other_set_data(other)
       Enum.all?(set_data(set_ref), &(&1 in od))
     end}
  end

  defp set_is_superset_fn(set_ref) do
    {:builtin, "isSupersetOf",
     fn [other | _], _ ->
       d = set_data(set_ref)
       Enum.all?(other_set_data(other), &(&1 in d))
     end}
  end

  defp set_is_disjoint_fn(set_ref) do
    {:builtin, "isDisjointFrom",
     fn [other | _], _ ->
       od = other_set_data(other)
       not Enum.any?(set_data(set_ref), &(&1 in od))
     end}
  end

  # ── Error static ──

  # ── Error static ──

  def error_static_property(_), do: :undefined
end
