defmodule QuickBEAM.BeamVM.Runtime.Builtins do
  alias QuickBEAM.BeamVM.Heap
  @moduledoc "Math, Number, Boolean, Console, constructors, and global functions."

  alias QuickBEAM.BeamVM.Runtime

  # ── Number.prototype ──

  def number_proto_property("toString"),
    do: {:builtin, "toString", fn args, this -> number_to_string(this, args) end}

  def number_proto_property("toFixed"),
    do: {:builtin, "toFixed", fn args, this -> number_to_fixed(this, args) end}

  def number_proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}

  def number_proto_property("toExponential"),
    do: {:builtin, "toExponential", fn args, this -> number_to_exponential(this, args) end}

  def number_proto_property("toPrecision"),
    do: {:builtin, "toPrecision", fn args, this -> number_to_precision(this, args) end}

  def number_proto_property(_), do: :undefined

  # ── Number static ──

  def number_static_property("isNaN"), do: {:builtin, "isNaN", fn [a | _] -> a == :nan end}

  def number_static_property("isFinite"),
    do:
      {:builtin, "isFinite",
       fn [a | _] -> a != :nan and a != :infinity and a != :neg_infinity end}

  def number_static_property("isInteger"),
    do:
      {:builtin, "isInteger",
       fn [a | _] -> is_integer(a) or (is_float(a) and a == Float.floor(a)) end}

  def number_static_property("parseInt"),
    do: {:builtin, "parseInt", fn args -> __MODULE__.parse_int(args) end}

  def number_static_property("parseFloat"),
    do: {:builtin, "parseFloat", fn args -> __MODULE__.parse_float(args) end}

  def number_static_property("NaN"), do: :nan
  def number_static_property("POSITIVE_INFINITY"), do: :infinity
  def number_static_property("NEGATIVE_INFINITY"), do: :neg_infinity
  def number_static_property("MAX_SAFE_INTEGER"), do: 9_007_199_254_740_991
  def number_static_property("MIN_SAFE_INTEGER"), do: -9_007_199_254_740_991
  def number_static_property(_), do: :undefined

  def string_static_property("fromCharCode") do
    {:builtin, "fromCharCode",
     fn args ->
       Enum.map(args, fn n ->
         cp = Runtime.to_int(n)
         if cp >= 0 and cp <= 0x10FFFF, do: <<cp::utf8>>, else: ""
       end)
       |> Enum.join()
     end}
  end

  def string_static_property("raw") do
    {:builtin, "raw",
     fn [strings | subs] ->
       map =
         case strings do
           {:obj, ref} -> QuickBEAM.BeamVM.Heap.get_obj(ref, %{})
           _ -> %{}
         end

       raw_map =
         case Map.get(map, "raw") do
           {:obj, rref} -> QuickBEAM.BeamVM.Heap.get_obj(rref, %{})
           _ -> map
         end

       len = Map.get(raw_map, "length", 0)

       Enum.reduce(0..(len - 1), "", fn i, acc ->
         part = Map.get(raw_map, Integer.to_string(i), "")

         sub =
           if i < length(subs),
             do: QuickBEAM.BeamVM.Runtime.js_to_string(Enum.at(subs, i)),
             else: ""

         acc <> QuickBEAM.BeamVM.Runtime.js_to_string(part) <> sub
       end)
     end}
  end

  def string_static_property(_), do: :undefined

  defp number_to_string(n, [radix | _]) when is_number(n) do
    case Runtime.to_int(radix) do
      10 -> QuickBEAM.BeamVM.Interpreter.Values.to_js_string(n * 1.0)
      16 -> Integer.to_string(trunc(n), 16) |> String.downcase()
      2 -> Integer.to_string(trunc(n), 2)
      8 -> Integer.to_string(trunc(n), 8)
      _ -> Runtime.js_to_string(n)
    end
  end

  defp number_to_string(n, _), do: Runtime.js_to_string(n)

  defp number_to_fixed(:nan, _), do: "NaN"
  defp number_to_fixed(:infinity, _), do: "Infinity"
  defp number_to_fixed(:neg_infinity, _), do: "-Infinity"

  defp number_to_fixed(n, [digits | _]) when is_number(n) do
    d = max(0, Runtime.to_int(digits))
    s = :erlang.float_to_binary(n * 1.0, decimals: d)

    if d > 0 do
      s
    else
      String.trim_trailing(s, ".0")
    end
  end

  defp number_to_fixed(n, _), do: Runtime.js_to_string(n)

  defp number_to_exponential(n, [digits | _]) when is_number(n) do
    d = Runtime.to_int(digits)
    f = n * 1.0
    exp = if f == 0.0, do: 0, else: trunc(:math.floor(:math.log10(abs(f))))
    mantissa = f / :math.pow(10, exp)
    sign = if exp >= 0, do: "+", else: ""
    :erlang.float_to_binary(mantissa, decimals: d) <> "e" <> sign <> Integer.to_string(exp)
  end

  defp number_to_exponential(n, _), do: Runtime.js_to_string(n)

  defp number_to_precision(n, [prec | _]) when is_number(n) do
    p = max(1, Runtime.to_int(prec))
    s = :erlang.float_to_binary(n * 1.0, [{:decimals, p + 10}, :compact])
    # Round to p significant digits
    {sign, abs_s} =
      if String.starts_with?(s, "-"), do: {"-", String.trim_leading(s, "-")}, else: {"", s}

    case Float.parse(abs_s) do
      {f, _} ->
        if f == 0.0 do
          sign <> "0" <> if(p > 1, do: "." <> String.duplicate("0", p - 1), else: "")
        else
          exp = :math.floor(:math.log10(abs(f)))
          rounded = Float.round(f / :math.pow(10, exp - p + 1)) * :math.pow(10, exp - p + 1)

          QuickBEAM.BeamVM.Interpreter.Values.to_js_string(
            if sign == "-", do: -rounded, else: rounded
          )
        end

      _ ->
        Runtime.js_to_string(n)
    end
  end

  defp number_to_precision(n, _), do: Runtime.js_to_string(n)

  # ── Boolean.prototype ──

  def boolean_proto_property("toString"),
    do: {:builtin, "toString", fn _args, this -> Atom.to_string(this) end}

  def boolean_proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}
  def boolean_proto_property(_), do: :undefined

  # ── Math ──

  def math_object do
    {:builtin, "Math",
     %{
       "floor" => {:builtin, "floor", fn [a | _] -> floor(Runtime.to_float(a)) end},
       "ceil" => {:builtin, "ceil", fn [a | _] -> ceil(Runtime.to_float(a)) end},
       "round" => {:builtin, "round", fn [a | _] -> round(Runtime.to_float(a)) end},
       "abs" => {:builtin, "abs", fn [a | _] -> abs(a) end},
       "max" =>
         {:builtin, "max",
          fn
            [] -> :neg_infinity
            args -> Enum.max(args)
          end},
       "min" =>
         {:builtin, "min",
          fn
            [] -> :infinity
            args -> Enum.min(args)
          end},
       "sqrt" => {:builtin, "sqrt", fn [a | _] -> :math.sqrt(Runtime.to_float(a)) end},
       "pow" =>
         {:builtin, "pow",
          fn [a, b | _] -> :math.pow(Runtime.to_float(a), Runtime.to_float(b)) end},
       "random" => {:builtin, "random", fn _ -> :rand.uniform() end},
       "trunc" => {:builtin, "trunc", fn [a | _] -> trunc(Runtime.to_float(a)) end},
       "sign" =>
         {:builtin, "sign",
          fn [a | _] ->
            cond do
              is_number(a) and a > 0 -> 1
              is_number(a) and a < 0 -> -1
              is_number(a) -> a
              true -> :nan
            end
          end},
       "log" => {:builtin, "log", fn [a | _] -> :math.log(Runtime.to_float(a)) end},
       "log2" => {:builtin, "log2", fn [a | _] -> :math.log2(Runtime.to_float(a)) end},
       "log10" => {:builtin, "log10", fn [a | _] -> :math.log10(Runtime.to_float(a)) end},
       "sin" => {:builtin, "sin", fn [a | _] -> :math.sin(Runtime.to_float(a)) end},
       "cos" => {:builtin, "cos", fn [a | _] -> :math.cos(Runtime.to_float(a)) end},
       "tan" => {:builtin, "tan", fn [a | _] -> :math.tan(Runtime.to_float(a)) end},
       "PI" => :math.pi(),
       "E" => :math.exp(1),
       "LN2" => :math.log(2),
       "LN10" => :math.log(10),
       "LOG2E" => :math.log2(:math.exp(1)),
       "LOG10E" => :math.log10(:math.exp(1)),
       "SQRT2" => :math.sqrt(2),
       "SQRT1_2" => :math.sqrt(2) / 2,
       "MAX_SAFE_INTEGER" => 9_007_199_254_740_991,
       "MIN_SAFE_INTEGER" => -9_007_199_254_740_991,
       "clz32" =>
         {:builtin, "clz32",
          fn [a | _] ->
            n = QuickBEAM.BeamVM.Interpreter.Values.to_uint32(a)
            if n == 0, do: 32, else: 31 - trunc(:math.log2(n))
          end},
       "fround" =>
         {:builtin, "fround",
          fn [a | _] ->
            f = Runtime.to_float(a)
            <<f32::float-32>> = <<f::float-32>>
            f32 * 1.0
          end},
       "imul" =>
         {:builtin, "imul",
          fn [a, b | _] ->
            QuickBEAM.BeamVM.Interpreter.Values.to_int32(
              QuickBEAM.BeamVM.Interpreter.Values.to_int32(a) *
                QuickBEAM.BeamVM.Interpreter.Values.to_int32(b)
            )
          end},
       "atan2" =>
         {:builtin, "atan2",
          fn [a, b | _] -> :math.atan2(Runtime.to_float(a), Runtime.to_float(b)) end},
       "asin" => {:builtin, "asin", fn [a | _] -> :math.asin(Runtime.to_float(a)) end},
       "acos" => {:builtin, "acos", fn [a | _] -> :math.acos(Runtime.to_float(a)) end},
       "atan" => {:builtin, "atan", fn [a | _] -> :math.atan(Runtime.to_float(a)) end},
       "exp" => {:builtin, "exp", fn [a | _] -> :math.exp(Runtime.to_float(a)) end},
       "cbrt" =>
         {:builtin, "cbrt",
          fn [a | _] ->
            f = Runtime.to_float(a)
            sign = if f < 0, do: -1, else: 1
            sign * :math.pow(abs(f), 1.0 / 3.0)
          end},
       "log1p" => {:builtin, "log1p", fn [a | _] -> :math.log(1 + Runtime.to_float(a)) end},
       "expm1" => {:builtin, "expm1", fn [a | _] -> :math.exp(Runtime.to_float(a)) - 1 end},
       "cosh" => {:builtin, "cosh", fn [a | _] -> :math.cosh(Runtime.to_float(a)) end},
       "sinh" => {:builtin, "sinh", fn [a | _] -> :math.sinh(Runtime.to_float(a)) end},
       "tanh" => {:builtin, "tanh", fn [a | _] -> :math.tanh(Runtime.to_float(a)) end},
       "acosh" => {:builtin, "acosh", fn [a | _] -> :math.acosh(Runtime.to_float(a)) end},
       "asinh" => {:builtin, "asinh", fn [a | _] -> :math.asinh(Runtime.to_float(a)) end},
       "atanh" => {:builtin, "atanh", fn [a | _] -> :math.atanh(Runtime.to_float(a)) end},
       "sumPrecise" =>
         {:builtin, "sumPrecise",
          fn [arr | _] ->
            list =
              case arr do
                {:obj, ref} ->
                  data = QuickBEAM.BeamVM.Heap.get_obj(ref, [])
                  if is_list(data), do: data, else: []

                l when is_list(l) ->
                  l

                _ ->
                  []
              end

            Enum.reduce(list, 0.0, fn v, acc -> acc + Runtime.to_float(v) end)
          end},
       "hypot" =>
         {:builtin, "hypot",
          fn args ->
            sum = Enum.reduce(args, 0.0, fn a, acc -> acc + :math.pow(Runtime.to_float(a), 2) end)
            :math.sqrt(sum)
          end}
     }}
  end

  # ── Console ──

  def console_object do
    ref = make_ref()

    Heap.put_obj(ref, %{
      "log" =>
        {:builtin, "log",
         fn args ->
           IO.puts(Enum.map(args, &Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "warn" =>
        {:builtin, "warn",
         fn args ->
           IO.warn(Enum.map(args, &Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "error" =>
        {:builtin, "error",
         fn args ->
           IO.puts(:stderr, Enum.map(args, &Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "info" =>
        {:builtin, "info",
         fn args ->
           IO.puts(Enum.map(args, &Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "debug" =>
        {:builtin, "debug",
         fn args ->
           IO.puts(Enum.map(args, &Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end}
    })

    {:obj, ref}
  end

  # ── Constructors ──

  def object_constructor, do: fn _args -> Runtime.obj_new() end

  def array_constructor do
    fn args ->
      list =
        case args do
          [n] when is_integer(n) and n >= 0 -> List.duplicate(:undefined, n)
          _ -> args
        end

      ref = make_ref()
      Heap.put_obj(ref, list)
      {:obj, ref}
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
      ref = make_ref()
      Heap.put_obj(ref, %{"message" => Runtime.js_to_string(msg), "stack" => ""})
      {:obj, ref}
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

      ref = make_ref()
      Heap.put_obj(ref, %{"valueOf" => ms})
      {:obj, ref}
    end
  end

  def promise_constructor do
    fn _args ->
      ref = make_ref()
      Heap.put_obj(ref, %{})
      {:obj, ref}
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
                     %{"__promise_state__" => :resolved, "__promise_value__" => val} -> val
                     _ -> item
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
                       %{"__promise_state__" => :resolved, "__promise_value__" => v} ->
                         {"fulfilled", v}

                       %{"__promise_state__" => :rejected, "__promise_value__" => v} ->
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
                     %{"__promise_state__" => :resolved, "__promise_value__" => v} -> v
                     _ -> nil
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
                       %{"__promise_state__" => :resolved, "__promise_value__" => v} -> v
                       _ -> first
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

  def parse_int([s, radix | _]) when is_binary(s) and is_number(radix) do
    r = trunc(radix)
    s = String.trim_leading(s)

    case Integer.parse(s, r) do
      {n, _} -> n
      :error -> :nan
    end
  end

  def parse_int([s | _]) when is_binary(s) do
    s = String.trim_leading(s)

    cond do
      String.starts_with?(s, "0x") or String.starts_with?(s, "0X") ->
        case Integer.parse(String.slice(s, 2..-1//1), 16) do
          {n, _} -> n
          :error -> :nan
        end

      true ->
        case Integer.parse(s) do
          {n, _} -> n
          :error -> :nan
        end
    end
  end

  def parse_int([n | _]) when is_number(n), do: trunc(n)
  def parse_int(_), do: :nan

  def parse_float([s | _]) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      {f, _} -> f
      :error -> :nan
    end
  end

  def parse_float([n | _]) when is_number(n), do: n * 1.0
  def parse_float(_), do: :nan

  def is_nan([:nan | _]), do: true
  def is_nan([n | _]) when is_number(n), do: false

  def is_nan([s | _]) when is_binary(s) do
    case Float.parse(s) do
      :error -> true
      _ -> false
    end
  end

  def is_nan(_), do: true

  def is_finite([n | _])
      when is_number(n) and n != :infinity and n != :neg_infinity and n != :nan,
      do: true

  def is_finite(_), do: false

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

      map_obj = %{"__map_data__" => entries, "size" => map_size(entries)}
      Heap.put_obj(ref, map_obj)
      {:obj, ref}
    end
  end

  def set_constructor do
    fn args ->
      ref = make_ref()

      items =
        case args do
          [list] when is_list(list) ->
            Enum.uniq(list)

          [{:obj, r}] ->
            stored = Heap.get_obj(r, [])
            if is_list(stored), do: Enum.uniq(stored), else: []

          _ ->
            []
        end

      set_ref = ref

      values_fn =
        {:builtin, "values",
         fn _, _ ->
           data = Map.get(Heap.get_obj(set_ref, %{}), "__set_data__", [])
           iter_ref = make_ref()
           pos_ref = make_ref()
           Heap.put_obj(pos_ref, %{pos: 0, list: data})

           next_fn =
             {:builtin, "next",
              fn _, _ ->
                state = Heap.get_obj(pos_ref, %{pos: 0, list: []})
                list = if is_list(state.list), do: state.list, else: []

                if state.pos >= length(list) do
                  r = make_ref()
                  Heap.put_obj(r, %{"value" => :undefined, "done" => true})
                  Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
                  {:obj, r}
                else
                  val = Enum.at(list, state.pos)
                  r = make_ref()
                  Heap.put_obj(r, %{"value" => val, "done" => false})
                  Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
                  {:obj, r}
                end
              end}

           Heap.put_obj(iter_ref, %{"next" => next_fn})
           {:obj, iter_ref}
         end}

      add_fn =
        {:builtin, "add",
         fn [val | _], _ ->
           data = Map.get(Heap.get_obj(set_ref, %{}), "__set_data__", [])

           unless val in data do
             new_data = data ++ [val]
             map = Heap.get_obj(set_ref, %{})

             Heap.put_obj(set_ref, %{map | "__set_data__" => new_data, "size" => length(new_data)})
           end

           {:obj, set_ref}
         end}

      entries_fn =
        {:builtin, "entries",
         fn _, _ ->
           data = Map.get(Heap.get_obj(set_ref, %{}), "__set_data__", [])

           pairs =
             Enum.map(data, fn v ->
               r = make_ref()
               Heap.put_obj(r, [v, v])
               {:obj, r}
             end)

           r = make_ref()
           Heap.put_obj(r, pairs)
           {:obj, r}
         end}

      set_obj = %{
        "__set_data__" => items,
        "size" => length(items),
        {:symbol, "Symbol.iterator"} => values_fn,
        "values" => values_fn,
        "keys" => values_fn,
        "entries" => entries_fn,
        "add" => add_fn
      }

      Heap.put_obj(ref, set_obj)
      {:obj, ref}
    end
  end

  # ── Error static ──

  def error_static_property(_), do: :undefined
end
