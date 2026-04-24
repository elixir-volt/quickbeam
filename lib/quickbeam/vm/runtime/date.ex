defmodule QuickBEAM.VM.Runtime.Date do
  @moduledoc false

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Heap

  @epoch_gs 719_528 * 86_400

  # ── Constructor ──

  def constructor(_args, nil) do
    ms = System.system_time(:millisecond)

    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%a %b %d %Y %H:%M:%S GMT+0000 (UTC)")
      _ -> "Invalid Date"
    end
  end

  def constructor(args, _this) do
    ms =
      case args do
        [] -> System.system_time(:millisecond)
        [val] when is_number(val) -> trunc(val)
        [s] when is_binary(s) -> parse_date_string(s)
        [_ | _] when length(args) >= 2 -> local_from_components(args)
        _ -> System.system_time(:millisecond)
      end

    Heap.wrap(%{date_ms() => ms})
  end

  # ── Statics ──

  static("now", do: System.system_time(:millisecond))
  static("parse", do: parse_date_string(to_string(hd(args))))
  static("UTC", do: utc_from_components(args))

  # ── Getters ──

  proto("getTime", do: get_ms(this))
  proto("valueOf", do: get_ms(this))
  proto("getFullYear", do: dt_field(this, :year))
  proto("getMonth", do: dt_field(this, :month, &(&1 - 1)))
  proto("getDate", do: dt_field(this, :day))
  proto("getHours", do: dt_field(this, :hour))
  proto("getMinutes", do: dt_field(this, :minute))
  proto("getSeconds", do: dt_field(this, :second))
  proto("getMilliseconds", do: with_ms(this, &rem(&1, 1000)))
  proto("getUTCFullYear", do: dt_field(this, :year))
  proto("getDay", do: with_dt(this, &(Date.day_of_week(&1) |> rem(7))))
  proto("getTimezoneOffset", do: tz_offset_minutes())

  # ── Setters ──

  proto("setTime", do: put_ms(this, hd(args)))
  proto("setFullYear", do: set_fields(this, [:year], args))
  proto("setMonth", do: set_field(this, :month, trunc(hd(args)) + 1))
  proto("setDate", do: set_fields(this, [:day], args))
  proto("setHours", do: set_fields(this, [:hour, :minute, :second], args))
  proto("setMinutes", do: set_fields(this, [:minute, :second], args))
  proto("setSeconds", do: set_fields(this, [:second], args))
  proto("setMilliseconds", do: set_ms_field(this, args))
  proto("setUTCHours", do: set_fields(this, [:hour, :minute, :second], args))
  proto("setUTCMinutes", do: set_fields(this, [:minute, :second], args))
  proto("setUTCSeconds", do: set_fields(this, [:second], args))
  proto("setUTCMilliseconds", do: set_ms_field(this, args))
  proto("setUTCFullYear", do: set_fields(this, [:year], args))
  proto("setUTCMonth", do: set_field(this, :month, trunc(hd(args)) + 1))
  proto("setUTCDate", do: set_fields(this, [:day], args))

  # ── Formatting ──

  proto("toISOString", do: fmt_dt(this, &DateTime.to_iso8601/1))
  proto("toJSON", do: fmt_dt(this, &DateTime.to_iso8601/1))

  proto("toString",
    do: fmt_dt(this, &Calendar.strftime(&1, "%a %b %d %Y %H:%M:%S GMT+0000 (UTC)"))
  )

  proto("toDateString", do: fmt_dt(this, &Calendar.strftime(&1, "%a %b %d %Y")))
  proto("toTimeString", do: fmt_dt(this, &Calendar.strftime(&1, "%H:%M:%S GMT+0000")))
  proto("toUTCString", do: fmt_dt(this, &Calendar.strftime(&1, "%a, %d %b %Y %H:%M:%S GMT")))
  proto("toLocaleTimeString", do: fmt_local(this, "%I:%M:%S %p"))
  proto("toLocaleDateString", do: fmt_local(this, "%m/%d/%Y"))
  proto("toLocaleString", do: fmt_local(this, "%m/%d/%Y, %I:%M:%S %p"))

  # ── Internal: ms ↔ DateTime ──

  defp get_ms({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{date_ms() => ms} -> ms
      _ -> :nan
    end
  end

  defp get_ms(_), do: :nan

  defp ms_to_dt(ms) when is_number(ms) do
    ms = trunc(ms)
    DateTime.from_gregorian_seconds(div(ms, 1000) + @epoch_gs, {rem(abs(ms), 1000) * 1000, 3})
  rescue
    _ -> nil
  end

  defp ms_to_dt(_), do: nil

  defp dt_field(this, field, transform \\ & &1) do
    case ms_to_dt(get_ms(this)) do
      nil -> :nan
      dt -> transform.(Map.get(dt, field))
    end
  end

  defp with_dt(this, fun) do
    case ms_to_dt(get_ms(this)) do
      nil -> :nan
      dt -> fun.(dt)
    end
  end

  defp with_ms(this, fun) do
    case get_ms(this) do
      ms when is_number(ms) -> fun.(trunc(ms))
      _ -> :nan
    end
  end

  defp fmt_dt(this, fun) do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> fun.(dt)
    end
  end

  defp fmt_local(this, pattern) do
    case ms_to_dt(get_ms(this)) do
      nil ->
        "Invalid Date"

      dt ->
        local_erl =
          :calendar.universal_time_to_local_time(
            {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second}}
          )

        Calendar.strftime(NaiveDateTime.from_erl!(local_erl), pattern)
    end
  end

  defp put_ms({:obj, ref}, ms) when is_number(ms) do
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), date_ms(), trunc(ms)))
    trunc(ms)
  end

  defp put_ms(_, _), do: :nan

  defp set_field(this, field, value) do
    case ms_to_dt(get_ms(this)) do
      nil -> :nan
      dt -> put_ms(this, DateTime.to_unix(Map.put(dt, field, trunc(value)), :millisecond))
    end
  rescue
    _ -> :nan
  end

  defp set_fields(this, fields, values) do
    case ms_to_dt(get_ms(this)) do
      nil ->
        :nan

      dt ->
        new_dt =
          Enum.zip(fields, values)
          |> Enum.reduce(dt, fn {field, val}, acc ->
            if is_number(val), do: Map.put(acc, field, trunc(val)), else: acc
          end)

        put_ms(this, DateTime.to_unix(new_dt, :millisecond))
    end
  rescue
    _ -> :nan
  end

  defp set_ms_field(this, args) do
    with_ms(this, &put_ms(this, div(&1, 1000) * 1000 + trunc(hd(args))))
  end

  defp tz_offset_minutes do
    {utc, local} = {:calendar.universal_time(), :calendar.local_time()}

    div(
      :calendar.datetime_to_gregorian_seconds(utc) -
        :calendar.datetime_to_gregorian_seconds(local),
      60
    )
  end

  # ── Date component → ms ──

  defp utc_from_components(args) do
    with {:ok, components} <- extract_components(args) do
      utc_ms(components)
    end
  end

  defp local_from_components(args) do
    with {:ok, {year, month, day, hour, minute, second, ms_part}} <- extract_components(args) do
      local_erl = {{year, month, max(day, 1)}, {hour, minute, second}}

      case :calendar.local_time_to_universal_time_dst(local_erl) do
        [utc_erl | _] ->
          local_ndt = NaiveDateTime.from_erl!(local_erl)
          utc_ndt = NaiveDateTime.from_erl!(utc_erl)
          offset_min = div(NaiveDateTime.diff(local_ndt, utc_ndt, :second) + 30, 60)

          DateTime.to_unix(DateTime.from_naive!(local_ndt, "Etc/UTC"), :millisecond) -
            offset_min * 60_000 + ms_part

        [] ->
          utc_ms({year, month, max(day, 1), hour, minute, second, ms_part}) -
            tz_offset_minutes() * -60_000
      end
    end
  rescue
    _ -> :nan
  end

  defp extract_components(args) do
    padded = args ++ List.duplicate(0, 7)
    count = min(length(args), 7)

    vals =
      padded
      |> Enum.take(count)
      |> Enum.map(fn
        v when v in [:nan, :NaN, :infinity, :neg_infinity] -> :nan
        v when is_number(v) -> v
        _ -> :nan
      end)

    if Enum.any?(vals, &(&1 == :nan)) do
      :nan
    else
      y = Enum.at(vals, 0, 0)
      year = if y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y)

      {:ok,
       {year, trunc(Enum.at(vals, 1, 0)) + 1, trunc(Enum.at(vals, 2, 1)),
        trunc(Enum.at(vals, 3, 0)), trunc(Enum.at(vals, 4, 0)), trunc(Enum.at(vals, 5, 0)),
        trunc(Enum.at(vals, 6, 0))}}
    end
  end

  defp utc_ms({year, month, day, hour, minute, second, ms_part}) do
    year = year + div(month - 1, 12)
    month = rem(rem(month - 1, 12) + 12, 12) + 1

    case make_day(year, month) do
      :nan ->
        :nan

      base_days ->
        day_f = (day - 1 + base_days) * 1.0

        time_ms =
          ((day_f * 24 + hour * 1.0) * 60 + minute * 1.0) * 60_000 +
            second * 1000.0 + ms_part * 1.0

        time_ms = trunc(time_ms)
        if abs(time_ms) > 8_640_000_000_000_000, do: :nan, else: time_ms
    end
  end

  defp make_day(year, month) when year >= 0 do
    :calendar.date_to_gregorian_days(year, month, 1) - 719_528
  rescue
    _ -> :nan
  end

  defp make_day(year, month) do
    y = if month <= 2, do: year - 1, else: year
    era = div(y - 399, 400)
    yoe = y - era * 400
    doy = div(153 * (month + if(month > 2, do: -3, else: 9)) + 2, 5)
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  # ── Date.parse ──

  def parse_date_string(s) when is_binary(s) do
    s = String.trim(s)
    if s == "", do: :nan, else: do_parse(s)
  end

  def parse_date_string(_), do: :nan

  defp do_parse(s) do
    s_expanded = expand_short_iso(s)
    has_explicit_tz = String.contains?(s, "Z") or has_tz_suffix?(s)
    has_time = String.contains?(s_expanded, "T")

    with :miss <- try_rfc3339(s_expanded, has_explicit_tz, has_time),
         :miss <- try_iso_date(s),
         :miss <- try_informal(s),
         :miss <- try_partial(s) do
      :nan
    end
  end

  defp has_tz_suffix?(s) when byte_size(s) >= 6,
    do: String.at(s, -6) in ["+", "-"] and String.at(s, -3) == ":"

  defp has_tz_suffix?(_), do: false

  defp try_rfc3339(s, has_explicit_tz, has_time) do
    with_tz =
      cond do
        String.contains?(s, "Z") or has_tz_suffix?(s) -> s
        String.contains?(s, "T") -> s <> "Z"
        true -> s
      end

    case safe_rfc3339_parse(with_tz) do
      {:ok, ms} ->
        if has_time and not has_explicit_tz,
          do: ms + tz_offset_minutes() * 60_000,
          else: ms

      :error ->
        :miss
    end
  end

  defp safe_rfc3339_parse(s) do
    us = :calendar.rfc3339_to_system_time(String.to_charlist(s), unit: :microsecond)
    {:ok, div(us, 1000)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp try_iso_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> utc_ms({d.year, d.month, d.day, 0, 0, 0, 0})
      _ -> :miss
    end
  end

  defp try_partial(s) do
    {sign, digits, has_sign} =
      case s do
        "+" <> r -> {1, r, true}
        "-" <> r -> {-1, r, true}
        r -> {1, r, false}
      end

    valid_year_len? = &(byte_size(&1) == 4 or (byte_size(&1) == 6 and has_sign))

    case String.split(digits, "-", parts: 3) do
      [y] ->
        if valid_year_len?.(y) do
          case Integer.parse(y) do
            {year, ""} -> utc_ms({sign * year, 1, 1, 0, 0, 0, 0})
            _ -> :miss
          end
        else
          :miss
        end

      [y, m] ->
        if valid_year_len?.(y) do
          with {year, ""} <- Integer.parse(y),
               {month, ""} <- Integer.parse(m),
               do: utc_ms({sign * year, month, 1, 0, 0, 0, 0}),
               else: (_ -> :miss)
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  # ── Informal date parsing ──

  @month_names %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @day_names ~w(sun mon tue wed thu fri sat)

  defp try_informal(s) do
    s = strip_day_name(String.trim(s))

    case String.split(s, " ", parts: 4) do
      [a, b, c | rest] ->
        time_tz = String.trim(Enum.join(rest, " "))

        result =
          if byte_size(a) == 4, do: parse_ymd(a, b, c), else: parse_mdy(a, b, c)

        case result do
          {:ok, year, month, day} ->
            {hour, minute, second, tz_offset} = parse_informal_time(time_tz)

            if tz_offset != nil do
              utc_ms({year, month, day, hour, minute, second, 0}) - tz_offset * 60_000
            else
              local_from_components([year, month - 1, day, hour, minute, second, 0])
            end

          :miss ->
            :miss
        end

      _ ->
        :miss
    end
  end

  defp strip_day_name(s) do
    case String.split(s, " ", parts: 2) do
      [w, rest] ->
        if String.downcase(String.slice(w, 0..2)) in @day_names, do: rest, else: s

      _ ->
        s
    end
  end

  defp parse_ymd(year_str, month_str, day_str) do
    with {year, ""} <- Integer.parse(year_str),
         month when is_integer(month) <-
           Map.get(@month_names, String.downcase(String.slice(month_str, 0..2))),
         {day, ""} <- Integer.parse(day_str) do
      {:ok, year, month, day}
    else
      _ -> :miss
    end
  end

  defp parse_mdy(month_str, day_str, year_str) do
    with month when is_integer(month) <-
           Map.get(@month_names, String.downcase(String.slice(month_str, 0..2))),
         {day, ""} <- Integer.parse(day_str),
         {year, ""} <- Integer.parse(year_str) do
      {:ok, year, month, day}
    else
      _ -> :miss
    end
  end

  defp parse_informal_time(""), do: {0, 0, 0, nil}

  defp parse_informal_time(s) do
    parts = String.split(s, " ")
    {time_part, rest} = List.pop_at(parts, 0, "")

    {ampm, tz_parts} =
      case rest do
        [p | r] when p in ~w(AM PM am pm) -> {String.downcase(p), r}
        r -> {nil, r}
      end

    {h, m, sec} =
      case String.split(time_part, ":") do
        [hh, mm, ss] -> {String.to_integer(hh), String.to_integer(mm), String.to_integer(ss)}
        [hh, mm] -> {String.to_integer(hh), String.to_integer(mm), 0}
        _ -> {0, 0, 0}
      end

    h =
      case ampm do
        "am" -> if h == 12, do: 0, else: h
        "pm" -> if h == 12, do: 12, else: h + 12
        nil -> h
      end

    tz_str = String.trim(Enum.join(tz_parts, " "))
    {h, m, sec, if(tz_str == "", do: nil, else: parse_tz_offset(tz_str))}
  end

  defp parse_tz_offset(""), do: 0
  defp parse_tz_offset("Z"), do: 0
  defp parse_tz_offset("GMT" <> rest), do: parse_tz_offset(rest)
  defp parse_tz_offset("UTC" <> rest), do: parse_tz_offset(rest)
  defp parse_tz_offset("+" <> o), do: parse_tz_minutes(o)
  defp parse_tz_offset("-" <> o), do: -parse_tz_minutes(o)
  defp parse_tz_offset(_), do: 0

  defp parse_tz_minutes(<<h::binary-2, m::binary-2>>),
    do: String.to_integer(h) * 60 + String.to_integer(m)

  defp parse_tz_minutes(s) do
    case Integer.parse(s) do
      {n, ""} -> n * 60
      _ -> 0
    end
  end

  # ── ISO helpers ──

  defp expand_short_iso(<<y1, y2, y3, y4, ?T, rest::binary>>)
       when y1 in ?0..?9 and y2 in ?0..?9 and y3 in ?0..?9 and y4 in ?0..?9,
       do: pad_seconds(<<y1, y2, y3, y4, "-01-01T", rest::binary>>)

  defp expand_short_iso(<<y1, y2, y3, y4, ?-, m1, m2, ?T, rest::binary>>)
       when y1 in ?0..?9 and y2 in ?0..?9 and y3 in ?0..?9 and y4 in ?0..?9 and
              m1 in ?0..?9 and m2 in ?0..?9,
       do: pad_seconds(<<y1, y2, y3, y4, ?-, m1, m2, "-01T", rest::binary>>)

  defp expand_short_iso(s), do: pad_seconds(s)

  defp pad_seconds(s) do
    case String.split(s, "T", parts: 2) do
      [date, time] ->
        {time_part, tz} = split_time_tz(time)

        padded =
          case String.split(time_part, ":") do
            [h, m] -> h <> ":" <> m <> ":00"
            _ -> time_part
          end

        date <> "T" <> padded <> tz

      _ ->
        s
    end
  end

  defp split_time_tz(time) do
    cond do
      String.ends_with?(time, "Z") -> String.split_at(time, -1)
      byte_size(time) >= 6 and String.at(time, -6) in ["+", "-"] -> String.split_at(time, -6)
      true -> {time, ""}
    end
  end
end
