defmodule QuickBEAM.BeamVM.Runtime.Date do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap

  @epoch_gs 719_528 * 86_400

  # ── Constructor ──

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

  static "now" do
    System.system_time(:millisecond)
  end

  static "parse" do
    parse_date_string(to_string(hd(args)))
  end

  static "UTC" do
    utc_from_components(args)
  end

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
  proto("setFullYear", do: set_field(this, :year, hd(args)))
  proto("setMonth", do: set_field(this, :month, trunc(hd(args)) + 1))
  proto("setDate", do: set_field(this, :day, hd(args)))
  proto("setHours", do: set_field(this, :hour, hd(args)))
  proto("setMinutes", do: set_field(this, :minute, hd(args)))
  proto("setSeconds", do: set_field(this, :second, hd(args)))

  proto "setMilliseconds" do
    with_ms(this, &put_ms(this, div(&1, 1000) * 1000 + trunc(hd(args))))
  end

  # ── Formatting ──

  proto("toISOString", do: fmt_dt(this, &DateTime.to_iso8601/1))
  proto("toJSON", do: fmt_dt(this, &DateTime.to_iso8601/1))
  proto("toString", do: fmt_dt(this, &Calendar.strftime(&1, "%a %b %d %Y %H:%M:%S GMT+0000 (UTC)")))
  proto("toDateString", do: fmt_dt(this, &Calendar.strftime(&1, "%a %b %d %Y")))
  proto("toTimeString", do: fmt_dt(this, &Calendar.strftime(&1, "%H:%M:%S GMT+0000")))
  proto("toUTCString", do: fmt_dt(this, &Calendar.strftime(&1, "%a, %d %b %Y %H:%M:%S GMT")))
  proto("toLocaleTimeString", do: fmt_dt(this, &Calendar.strftime(&1, "%H:%M:%S")))

  proto("toLocaleDateString", do: fmt_dt(this, &"#{&1.month}/#{&1.day}/#{&1.year}"))

  proto "toLocaleString" do
    fmt_dt(this, &"#{&1.month}/#{&1.day}/#{&1.year}, #{Calendar.strftime(&1, "%H:%M:%S")}")
  end

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

  defp dt_to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

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

  defp put_ms({:obj, ref}, ms) when is_number(ms) do
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), date_ms(), trunc(ms)))
    trunc(ms)
  end

  defp put_ms(_, _), do: :nan

  defp set_field(this, field, value) do
    case ms_to_dt(get_ms(this)) do
      nil -> :nan
      dt ->
        put_ms(this, dt_to_ms(Map.put(dt, field, trunc(value))))
    end
  rescue
    _ -> :nan
  end

  defp tz_offset_minutes do
    {utc, local} = {:calendar.universal_time(), :calendar.local_time()}
    div(:calendar.datetime_to_gregorian_seconds(utc) - :calendar.datetime_to_gregorian_seconds(local), 60)
  end

  # ── Date component → ms ──

  defp utc_from_components(args) do
    with {:ok, components} <- extract_components(args, length(args)) do
      utc_ms(components)
    end
  end

  defp local_from_components(args) do
    with {:ok, {year, month, day, hour, minute, second, ms_part}} <- extract_components(args, length(args)) do
      local_dt = {{year, month, max(day, 1)}, {hour, minute, second}}

      case :calendar.local_time_to_universal_time_dst(local_dt) do
        [utc_erl | _] ->
          utc_dt = DateTime.from_naive!(NaiveDateTime.from_erl!(utc_erl), "Etc/UTC")
          local_gs = :calendar.datetime_to_gregorian_seconds(local_dt)
          utc_gs = :calendar.datetime_to_gregorian_seconds(utc_erl)
          offset_min = div(local_gs - utc_gs + 30, 60) * 60
          (local_gs - @epoch_gs - offset_min) * 1000 + ms_part

        [] ->
          utc_ms({year, month, max(day, 1), hour, minute, second, ms_part}) -
            local_tz_offset_minutes() * 60_000
      end
    end
  rescue
    _ -> :nan
  end

  defp extract_components(args, count) do
    padded = args ++ List.duplicate(0, 7)

    vals =
      Enum.map(Enum.take(padded, min(count, 7)), fn
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
       {year, trunc(Enum.at(vals, 1, 0)) + 1, max(1, trunc(Enum.at(vals, 2, 1))),
        trunc(Enum.at(vals, 3, 0)), trunc(Enum.at(vals, 4, 0)), trunc(Enum.at(vals, 5, 0)),
        trunc(Enum.at(vals, 6, 0))}}
    end
  end

  defp utc_ms({year, month, day, hour, minute, second, ms_part}) do
    dt = DateTime.from_naive!(NaiveDateTime.new!(year, month, day, hour, minute, second, {ms_part * 1000, 3}), "Etc/UTC")
    dt_to_ms(dt)
  rescue
    _ -> :nan
  end

  defp local_tz_offset_minutes do
    utc_gs = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    local_gs = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
    div(local_gs - utc_gs, 60)
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
          do: ms - local_tz_offset_minutes() * 60_000,
          else: ms

      :error ->
        :miss
    end
  end

  defp safe_rfc3339_parse(s) do
    {:ok, :calendar.rfc3339_to_system_time(String.to_charlist(s), unit: :millisecond)}
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
    {sign, digits} =
      case s do
        "+" <> r -> {1, r}
        "-" <> r -> {-1, r}
        r -> {1, r}
      end

    case String.split(digits, "-", parts: 3) do
      [year_str] ->
        with {year, ""} <- Integer.parse(year_str),
             do: utc_ms({sign * year, 1, 1, 0, 0, 0, 0}),
             else: (_ -> :miss)

      [year_str, month_str] ->
        with {year, ""} <- Integer.parse(year_str),
             {month, ""} <- Integer.parse(month_str),
             do: utc_ms({sign * year, month, 1, 0, 0, 0, 0}),
             else: (_ -> :miss)

      _ ->
        :miss
    end
  end

  # ── Informal date parsing ──

  @month_names %{
    "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6,
    "jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12
  }

  @day_names ~w(sun mon tue wed thu fri sat)

  defp try_informal(s) do
    s = String.trim(s)

    s =
      case String.split(s, " ", parts: 2) do
        [w, rest] ->
          if String.downcase(String.slice(w, 0..2)) in @day_names, do: rest, else: s

        _ ->
          s
      end

    case Regex.run(~r/^(\w{3})\s+(\d{1,2})\s+(\d{4})\s*(.*)$/i, s) do
      [_, month_str, day_str, year_str, time_tz] ->
        with month when is_integer(month) <- Map.get(@month_names, String.downcase(String.slice(month_str, 0..2))),
             {day, ""} <- Integer.parse(day_str),
             {year, ""} <- Integer.parse(year_str) do
          {hour, minute, second, tz_offset} = parse_informal_time(String.trim(time_tz))

          if tz_offset != nil do
            utc_ms({year, month, day, hour, minute, second, 0}) - tz_offset * 60_000
          else
            local_from_components([year, month - 1, day, hour, minute, second, 0])
          end
        else
          _ -> :miss
        end

      _ ->
        :miss
    end
  end

  defp parse_informal_time(""), do: {0, 0, 0, nil}

  defp parse_informal_time(s) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(.*)$/, s) do
      [_, h, m, sec, tz] ->
        {String.to_integer(h), String.to_integer(m),
         (if sec != "", do: String.to_integer(sec), else: 0),
         (if tz == "", do: nil, else: parse_tz_offset(String.trim(tz)))}

      _ ->
        {0, 0, 0, nil}
    end
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

  defp expand_short_iso(s) do
    s =
      case Regex.run(~r/^(\d{4})T(.+)$/, s) do
        [_, year, time] -> "#{year}-01-01T#{time}"
        _ ->
          case Regex.run(~r/^(\d{4})-(\d{2})T(.+)$/, s) do
            [_, year, month, time] -> "#{year}-#{month}-01T#{time}"
            _ -> s
          end
      end

    pad_seconds(s)
  end

  defp pad_seconds(s) do
    case String.split(s, "T", parts: 2) do
      [date, time] ->
        {time_part, tz} = split_time_tz(time)

        padded =
          case String.split(time_part, ":") do
            [h, m] -> "#{h}:#{m}:00"
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
