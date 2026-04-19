defmodule QuickBEAM.BeamVM.Runtime.Date do
  import QuickBEAM.BeamVM.Heap.Keys
  @moduledoc false
  alias QuickBEAM.BeamVM.Heap

  def constructor(args) do
    ms =
      case args do
        [] ->
          System.system_time(:millisecond)

        [val | _] when is_number(val) ->
          trunc(val)

        [s | _] when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
            _ -> :nan
          end

        _ ->
          System.system_time(:millisecond)
      end

    Heap.wrap(%{date_ms() => ms})
  end

  def statics do
    [
      {"now", static_now()},
      {"parse", {:builtin, "parse", fn [s | _] -> parse_date_string(to_string(s)) end}},
      {"UTC",
       {:builtin, "UTC",
        fn args ->
          [y | rest] = args ++ List.duplicate(0, 7)
          m = Enum.at(rest, 0, 0)
          d = Enum.at(rest, 1, 1)
          h = Enum.at(rest, 2, 0)
          mi = Enum.at(rest, 3, 0)
          s = Enum.at(rest, 4, 0)
          ms = Enum.at(rest, 5, 0)
          year = if is_number(y) and y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y || 0)

          case NaiveDateTime.new(
                 year,
                 trunc(m) + 1,
                 max(1, trunc(d)),
                 trunc(h),
                 trunc(mi),
                 trunc(s)
               ) do
            {:ok, dt} ->
              DateTime.from_naive!(dt, "Etc/UTC")
              |> DateTime.to_unix(:millisecond)
              |> Kernel.+(trunc(ms))

            _ ->
              :nan
          end
        end}}
    ]
  end

  def proto_property("getTime"), do: {:builtin, "getTime", fn _, this -> get_ms(this) end}
  def proto_property("valueOf"), do: {:builtin, "valueOf", fn _, this -> get_ms(this) end}

  def proto_property("getFullYear"),
    do:
      {:builtin, "getFullYear",
       fn _, this ->
         {{y, _, _}, _} = utc(this)
         y
       end}

  def proto_property("getMonth"),
    do:
      {:builtin, "getMonth",
       fn _, this ->
         {{_, m, _}, _} = utc(this)
         m - 1
       end}

  def proto_property("getDate"),
    do:
      {:builtin, "getDate",
       fn _, this ->
         {{_, _, d}, _} = utc(this)
         d
       end}

  def proto_property("getHours"),
    do:
      {:builtin, "getHours",
       fn _, this ->
         {_, {h, _, _}} = utc(this)
         h
       end}

  def proto_property("getMinutes"),
    do:
      {:builtin, "getMinutes",
       fn _, this ->
         {_, {_, m, _}} = utc(this)
         m
       end}

  def proto_property("getSeconds"),
    do:
      {:builtin, "getSeconds",
       fn _, this ->
         {_, {_, _, s}} = utc(this)
         s
       end}

  def proto_property("getMilliseconds"),
    do:
      {:builtin, "getMilliseconds",
       fn _, this ->
         rem(get_ms(this), 1000)
       end}

  def proto_property("toISOString"),
    do:
      {:builtin, "toISOString",
       fn _, this ->
         ms = get_ms(this)
         {{y, m, d}, {h, min, s}} = :calendar.system_time_to_universal_time(ms, :millisecond)

         :io_lib.format(
           "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
           [y, m, d, h, min, s, rem(ms, 1000)]
         )
         |> IO.iodata_to_binary()
       end}

  def proto_property("toJSON"), do: proto_property("toISOString")

  def proto_property("getTimezoneOffset"),
    do:
      {:builtin, "getTimezoneOffset",
       fn _, _this ->
         utc_now = :calendar.universal_time()
         local_now = :calendar.local_time()
         utc_s = :calendar.datetime_to_gregorian_seconds(utc_now)
         local_s = :calendar.datetime_to_gregorian_seconds(local_now)
         div(utc_s - local_s, 60)
       end}

  def proto_property("getDay"),
    do:
      {:builtin, "getDay",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> :nan
           # JS: 0=Sun..6=Sat. Elixir day_of_week: 1=Mon..7=Sun. rem(7) maps 7→0 (Sun). Mon(1)..Sat(6) unchanged.
           dt -> Date.day_of_week(DateTime.to_date(dt)) |> rem(7)
         end
       end}

  def proto_property("getUTCFullYear"),
    do:
      {:builtin, "getUTCFullYear",
       fn _, this ->
         case get_ms(this) do
           ms when is_number(ms) -> DateTime.from_unix!(trunc(ms), :millisecond).year
           _ -> :nan
         end
       end}

  def proto_property("setTime"),
    do:
      {:builtin, "setTime",
       fn [ms | _], this ->
         case this do
           {:obj, ref} ->
             map = QuickBEAM.BeamVM.Heap.get_obj(ref, %{})

             if is_map(map),
               do:
                 QuickBEAM.BeamVM.Heap.put_obj(
                   ref,
                   Map.put(map, date_ms(), ms)
                 )

             ms

           _ ->
             :nan
         end
       end}

  def proto_property("toLocaleDateString"),
    do:
      {:builtin, "toLocaleDateString",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> "Invalid Date"
           dt -> Calendar.strftime(dt, "%m/%d/%Y")
         end
       end}

  def proto_property("toLocaleTimeString"),
    do:
      {:builtin, "toLocaleTimeString",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> "Invalid Date"
           dt -> Calendar.strftime(dt, "%H:%M:%S")
         end
       end}

  def proto_property("toLocaleString"),
    do:
      {:builtin, "toLocaleString",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> "Invalid Date"
           dt -> Calendar.strftime(dt, "%m/%d/%Y, %H:%M:%S")
         end
       end}

  def proto_property("setFullYear"),
    do: {:builtin, "setFullYear", fn [v | _], this -> set_date_field(this, :year, v) end}

  def proto_property("setMonth"),
    do: {:builtin, "setMonth", fn [v | _], this -> set_date_field(this, :month, trunc(v) + 1) end}

  def proto_property("setDate"),
    do: {:builtin, "setDate", fn [v | _], this -> set_date_field(this, :day, v) end}

  def proto_property("setHours"),
    do: {:builtin, "setHours", fn [v | _], this -> set_date_field(this, :hour, v) end}

  def proto_property("setMinutes"),
    do: {:builtin, "setMinutes", fn [v | _], this -> set_date_field(this, :minute, v) end}

  def proto_property("setSeconds"),
    do: {:builtin, "setSeconds", fn [v | _], this -> set_date_field(this, :second, v) end}

  def proto_property("setMilliseconds"),
    do:
      {:builtin, "setMilliseconds",
       fn [ms | _], this ->
         case {get_ms(this), this} do
           {old_ms, {:obj, ref}} when is_number(old_ms) ->
             base = trunc(old_ms / 1000) * 1000
             new_ms = base + trunc(ms)

             QuickBEAM.BeamVM.Heap.put_obj(
               ref,
               Map.put(
                 QuickBEAM.BeamVM.Heap.get_obj(ref, %{}),
                 date_ms(),
                 new_ms
               )
             )

             new_ms

           _ ->
             :nan
         end
       end}

  def proto_property("toDateString"),
    do:
      {:builtin, "toDateString",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> "Invalid Date"
           dt -> Calendar.strftime(dt, "%a %b %d %Y")
         end
       end}

  def proto_property("toTimeString"),
    do:
      {:builtin, "toTimeString",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> "Invalid Date"
           dt -> Calendar.strftime(dt, "%H:%M:%S GMT+0000")
         end
       end}

  def proto_property("toUTCString"),
    do:
      {:builtin, "toUTCString",
       fn _, this ->
         case ms_to_dt(get_ms(this)) do
           nil -> "Invalid Date"
           dt -> Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
         end
       end}

  def proto_property("toString"),
    do:
      {:builtin, "toString",
       fn _, this ->
         ms = get_ms(this)
         {{y, m, d}, {h, min, s}} = :calendar.system_time_to_universal_time(ms, :millisecond)
         "#{y}-#{m}-#{d}T#{h}:#{min}:#{s}Z"
       end}

  def proto_property(_), do: :undefined

  def static_now do
    {:builtin, "now", fn _ -> System.system_time(:millisecond) end}
  end

  defp set_date_field(this, field, value) do
    case {get_ms(this), this} do
      {ms, {:obj, ref}} when is_number(ms) ->
        dt = DateTime.from_unix!(trunc(ms), :millisecond)

        fields = %{
          year: dt.year,
          month: dt.month,
          day: dt.day,
          hour: dt.hour,
          minute: dt.minute,
          second: dt.second
        }

        updated = Map.put(fields, field, trunc(value))

        case NaiveDateTime.new(
               updated.year,
               updated.month,
               updated.day,
               updated.hour,
               updated.minute,
               updated.second
             ) do
          {:ok, ndt} ->
            new_ms =
              DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix(:millisecond)

            QuickBEAM.BeamVM.Heap.put_obj(
              ref,
              Map.put(
                QuickBEAM.BeamVM.Heap.get_obj(ref, %{}),
                date_ms(),
                new_ms
              )
            )

            new_ms

          _ ->
            :nan
        end

      _ ->
        :nan
    end
  end

  defp get_ms({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{date_ms() => ms} -> ms
      _ -> :nan
    end
  end

  defp get_ms(_), do: :nan

  defp ms_to_dt(ms) when is_number(ms) do
    try do
      DateTime.from_unix!(trunc(ms), :millisecond)
    rescue
      _ -> nil
    end
  end

  defp ms_to_dt(_), do: nil

  def parse_date_string(s) when is_binary(s) do
    s = String.trim(s)

    cond do
      s == "" ->
        :nan

      # ISO 8601: YYYY-MM-DDTHH:mm:ss.sssZ
      Regex.match?(
        ~r/^[+-]?\d{4,6}(-\d{2}(-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?([+-]\d{2}:\d{2})?)?)?)?$/,
        s
      ) ->
        parse_iso(s)

      # Simple year: YYYY
      Regex.match?(~r/^\d{4}$/, s) ->
        parse_iso(s)

      true ->
        :nan
    end
  end

  def parse_date_string(_), do: :nan

  defp parse_iso(s) do
    try do
      # Extract components
      {sign, rest} =
        case s do
          "+" <> r -> {1, r}
          "-" <> r -> {-1, r}
          r -> {1, r}
        end

      parts = String.split(rest, ~r/[-T:Z.+]/, trim: true)
      year = sign * String.to_integer(Enum.at(parts, 0, "0"))
      month = String.to_integer(Enum.at(parts, 1, "1"))
      day = String.to_integer(Enum.at(parts, 2, "1"))
      hour = String.to_integer(Enum.at(parts, 3, "0"))
      minute = String.to_integer(Enum.at(parts, 4, "0"))
      second = String.to_integer(Enum.at(parts, 5, "0"))
      ms_str = Enum.at(parts, 6, "0")
      ms = String.to_integer(String.pad_trailing(String.slice(ms_str, 0, 3), 3, "0"))

      if month < 1 or month > 12 or day < 1 or day > 31 or
           hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59 do
        :nan
      else
        case NaiveDateTime.new(year, month, day, hour, minute, second) do
          {:ok, ndt} ->
            base = DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix(:millisecond)
            base + ms

          _ ->
            :nan
        end
      end
    rescue
      _ -> :nan
    end
  end

  defp utc(this) do
    case get_ms(this) do
      ms when is_integer(ms) -> :calendar.system_time_to_universal_time(ms, :millisecond)
      _ -> {{1970, 1, 1}, {0, 0, 0}}
    end
  end
end
