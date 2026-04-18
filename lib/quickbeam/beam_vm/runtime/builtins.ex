defmodule QuickBEAM.BeamVM.Runtime.Builtins do
  import QuickBEAM.BeamVM.InternalKeys
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
    r = Runtime.to_int(radix)

    cond do
      r == 10 ->
        QuickBEAM.BeamVM.Interpreter.Values.to_js_string(n * 1.0)

      r >= 2 and r <= 36 and n == trunc(n) ->
        Integer.to_string(trunc(n), r) |> String.downcase()

      r >= 2 and r <= 36 ->
        float_to_radix(n * 1.0, r)

      true ->
        Runtime.js_to_string(n)
    end
  end

  defp number_to_string(n, _), do: Runtime.js_to_string(n)

  defp float_to_radix(n, radix) do
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    {sign, n} = if n < 0, do: {"-", -n}, else: {"", n}
    int_part = trunc(n)
    frac_part = n - int_part

    int_str = if int_part == 0, do: "0", else: integer_to_radix(int_part, radix, digits, "")

    frac_str =
      if frac_part == 0.0 do
        ""
      else
        build_frac(frac_part, radix, digits, "", 0)
      end

    if frac_str == "", do: sign <> int_str, else: sign <> int_str <> "." <> frac_str
  end

  defp integer_to_radix(0, _radix, _digits, acc), do: acc

  defp integer_to_radix(n, radix, digits, acc) do
    integer_to_radix(
      div(n, radix),
      radix,
      digits,
      <<String.at(digits, rem(n, radix))::binary, acc::binary>>
    )
  end

  defp build_frac(_frac, _radix, _digits, acc, count) when count >= 20, do: acc

  defp build_frac(frac, radix, digits, acc, count) do
    prod = frac * radix
    digit = trunc(prod)
    rest = prod - digit
    new_acc = acc <> String.at(digits, digit)

    if rest == 0.0 or count >= 19,
      do: new_acc,
      else: build_frac(rest, radix, digits, new_acc, count + 1)
  end

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

  def error_static_property(_), do: :undefined
end
