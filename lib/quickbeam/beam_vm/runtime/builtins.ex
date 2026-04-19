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
           [val | _] -> QuickBEAM.BeamVM.Interpreter.Promise.resolved(val)
           [] -> QuickBEAM.BeamVM.Interpreter.Promise.resolved(:undefined)
         end},
      "reject" =>
        {:builtin, "reject",
         fn [val | _] ->
           QuickBEAM.BeamVM.Interpreter.Promise.rejected(val)
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
           QuickBEAM.BeamVM.Interpreter.Promise.resolved({:obj, result_ref})
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
           QuickBEAM.BeamVM.Interpreter.Promise.resolved({:obj, result_ref})
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

           QuickBEAM.BeamVM.Interpreter.Promise.resolved(result || :undefined)
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

               QuickBEAM.BeamVM.Interpreter.Promise.resolved(val)

             [] ->
               QuickBEAM.BeamVM.Interpreter.Promise.resolved(:undefined)
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

  def error_static_property(_), do: :undefined
end
