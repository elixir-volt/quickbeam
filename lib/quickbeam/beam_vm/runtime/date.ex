defmodule QuickBEAM.BeamVM.Runtime.Date do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap

  @epoch_days 719_528
  @epoch_gs @epoch_days * 86_400

  # ── Constructor ──

  def constructor(args, _this) do
    ms =
      case args do
        [] ->
          System.system_time(:millisecond)

        [val] when is_number(val) ->
          trunc(val)

        [s] when is_binary(s) ->
          parse_date_string(s)

        [_ | _] when length(args) >= 2 ->
          make_date_from_args(args)

        _ ->
          System.system_time(:millisecond)
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
    make_utc(args)
  end

  # ── Getters ──

  proto "getTime" do
    get_ms(this)
  end

  proto "valueOf" do
    get_ms(this)
  end

  proto "getFullYear" do
    dt_field(this, :year)
  end

  proto "getMonth" do
    dt_field(this, :month, &(&1 - 1))
  end

  proto "getDate" do
    dt_field(this, :day)
  end

  proto "getHours" do
    dt_field(this, :hour)
  end

  proto "getMinutes" do
    dt_field(this, :minute)
  end

  proto "getSeconds" do
    dt_field(this, :second)
  end

  proto "getMilliseconds" do
    with_ms(this, &rem(&1, 1000))
  end

  proto "getUTCFullYear" do
    dt_field(this, :year)
  end

  proto "getDay" do
    case ms_to_dt(get_ms(this)) do
      nil -> :nan
      dt -> Date.day_of_week(dt) |> rem(7)
    end
  end

  proto "getTimezoneOffset" do
    tz_offset_minutes()
  end

  # ── Setters ──

  proto "setTime" do
    put_ms(this, hd(args))
  end

  proto "setFullYear" do
    set_field(this, :year, hd(args))
  end

  proto "setMonth" do
    set_field(this, :month, trunc(hd(args)) + 1)
  end

  proto "setDate" do
    set_field(this, :day, hd(args))
  end

  proto "setHours" do
    set_field(this, :hour, hd(args))
  end

  proto "setMinutes" do
    set_field(this, :minute, hd(args))
  end

  proto "setSeconds" do
    set_field(this, :second, hd(args))
  end

  proto "setMilliseconds" do
    with_ms(this, &put_ms(this, div(&1, 1000) * 1000 + trunc(hd(args))))
  end

  # ── Formatting ──

  proto "toISOString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> DateTime.to_iso8601(dt)
    end
  end

  proto "toJSON" do
    {:builtin, _, cb} = proto_property("toISOString")
    cb.(args, this)
  end

  proto "toString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> Calendar.strftime(dt, "%a %b %d %Y %H:%M:%S GMT+0000 (UTC)")
    end
  end

  proto "toDateString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> Calendar.strftime(dt, "%a %b %d %Y")
    end
  end

  proto "toTimeString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> Calendar.strftime(dt, "%H:%M:%S GMT+0000")
    end
  end

  proto "toUTCString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
    end
  end

  proto "toLocaleDateString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> "#{dt.month}/#{dt.day}/#{dt.year}"
    end
  end

  proto "toLocaleTimeString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> Calendar.strftime(dt, "%H:%M:%S")
    end
  end

  proto "toLocaleString" do
    case ms_to_dt(get_ms(this)) do
      nil -> "Invalid Date"
      dt -> "#{dt.month}/#{dt.day}/#{dt.year}, #{Calendar.strftime(dt, "%H:%M:%S")}"
    end
  end

  # ── Internal: ms <-> datetime ──

  defp get_ms({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{date_ms() => ms} -> ms
      _ -> :nan
    end
  end

  defp get_ms(_), do: :nan

  defp ms_to_dt(ms) when is_number(ms) do
    ms = trunc(ms)
    gs = div(ms, 1000) + @epoch_gs
    frac = {rem(abs(ms), 1000) * 1000, 3}
    DateTime.from_gregorian_seconds(gs, frac)
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

  defp with_ms(this, fun) do
    case get_ms(this) do
      ms when is_number(ms) -> fun.(trunc(ms))
      _ -> :nan
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
        try do
          new_dt = Map.put(dt, field, trunc(value))
          put_ms(this, DateTime.to_unix(new_dt, :millisecond))
        rescue
          _ -> :nan
        end
    end
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp tz_offset_minutes do
    {utc, local} = {:calendar.universal_time(), :calendar.local_time()}
    div(:calendar.datetime_to_gregorian_seconds(utc) - :calendar.datetime_to_gregorian_seconds(local), 60)
  end

  # ── Date.UTC ──

  defp make_utc(args) do
    padded = args ++ List.duplicate(0, 7)

    vals =
      Enum.map(Enum.take(padded, min(length(args), 7)), fn
        v when v in [:nan, :NaN, :infinity, :neg_infinity] -> :nan
        v when is_number(v) -> v
        _ -> :nan
      end)

    if Enum.any?(vals, &(&1 == :nan)) do
      :nan
    else
      y = Enum.at(vals, 0, 0)
      year = if y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y)

      utc_ms(
        year,
        trunc(Enum.at(vals, 1, 0)) + 1,
        max(1, trunc(Enum.at(vals, 2, 1))),
        trunc(Enum.at(vals, 3, 0)),
        trunc(Enum.at(vals, 4, 0)),
        trunc(Enum.at(vals, 5, 0)),
        trunc(Enum.at(vals, 6, 0))
      )
    end
  end

  # ── new Date(year, month, ...) — local time ──

  defp make_date_from_args(args) do
    padded = args ++ List.duplicate(0, 7)
    y = Enum.at(padded, 0, 0)

    unless is_number(y), do: throw(:nan)

    year = if is_number(y) and y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y || 0)
    month = trunc(Enum.at(padded, 1, 0)) + 1
    day = trunc(Enum.at(padded, 2, 1))
    day = if day == 0, do: 1, else: day
    hour = trunc(Enum.at(padded, 3, 0))
    minute = trunc(Enum.at(padded, 4, 0))
    second = trunc(Enum.at(padded, 5, 0))
    ms_part = trunc(Enum.at(padded, 6, 0))

    local_to_utc_ms(year, month, max(day, 1), hour, minute, second, ms_part)
  catch
    :nan -> :nan
  end

  # ── Core: convert date components to UTC milliseconds ──

  defp utc_ms(year, month, day, hour, minute, second, ms) when year >= 0 do
    gs = :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})
    (gs - @epoch_days * 86_400) * 1000 + ms
  rescue
    _ -> :nan
  end

  defp utc_ms(year, month, day, hour, minute, second, ms) do
    (days_from_epoch(year, month, day) * 86_400 + :calendar.time_to_seconds({hour, minute, second})) * 1000 + ms
  end

  defp local_to_utc_ms(year, month, day, hour, minute, second, ms_part) do
    local_dt = {{year, month, day}, {hour, minute, second}}

    case :calendar.local_time_to_universal_time_dst(local_dt) do
      [utc_dt | _] ->
        local_gs = :calendar.datetime_to_gregorian_seconds(local_dt)
        utc_gs = :calendar.datetime_to_gregorian_seconds(utc_dt)
        offset_s = local_gs - utc_gs
        offset_min = div(offset_s + 30, 60) * 60
        (local_gs - @epoch_days * 86_400 - offset_min) * 1000 + ms_part

      [] ->
        utc = utc_ms(year, month, day, hour, minute, second, ms_part)
        if utc == :nan, do: :nan, else: utc - local_tz_offset_minutes() * 60_000
    end
  rescue
    _ -> :nan
  end

  defp local_tz_offset_minutes do
    utc_gs = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    local_gs = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
    div(local_gs - utc_gs, 60)
  end

  defp days_from_epoch(year, month, day) when year >= 0 do
    :calendar.date_to_gregorian_days(year, month, day) - @epoch_days
  end

  defp days_from_epoch(year, month, day) do
    y = if month <= 2, do: year - 1, else: year
    era = div(y - 399, 400)
    yoe = y - era * 400
    doy = div(153 * (month + (if month > 2, do: -3, else: 9)) + 2, 5) + day - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146097 + doe - 719_468
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
        String.contains?(s, "Z") -> s
        has_tz_suffix?(s) -> s
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
      {:ok, d} -> utc_ms(d.year, d.month, d.day, 0, 0, 0, 0)
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
        case Integer.parse(year_str) do
          {year, ""} -> utc_ms(sign * year, 1, 1, 0, 0, 0, 0)
          _ -> :miss
        end

      [year_str, month_str] ->
        with {year, ""} <- Integer.parse(year_str),
             {month, ""} <- Integer.parse(month_str) do
          utc_ms(sign * year, month, 1, 0, 0, 0, 0)
        else
          _ -> :miss
        end

      _ ->
        :miss
    end
  end

  # ── Informal date parsing ("Jan 1 2000", "Sat Jan 1 2000 00:00:00 GMT+0100") ──

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
        month = Map.get(@month_names, String.downcase(String.slice(month_str, 0..2)))

        if month do
          {day, ""} = Integer.parse(day_str)
          {year, ""} = Integer.parse(year_str)
          {hour, minute, second, tz_offset} = parse_informal_time(String.trim(time_tz))

          if tz_offset != nil do
            utc_ms(year, month, day, hour, minute, second, 0) - tz_offset * 60_000
          else
            local_to_utc_ms(year, month, day, hour, minute, second, 0)
          end
        else
          :miss
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
  defp parse_tz_offset("+" <> o), do: parse_tz_num(o)
  defp parse_tz_offset("-" <> o), do: -parse_tz_num(o)
  defp parse_tz_offset(_), do: 0

  defp parse_tz_num(s) when byte_size(s) == 4,
    do: String.to_integer(String.slice(s, 0..1)) * 60 + String.to_integer(String.slice(s, 2..3))

  defp parse_tz_num(s) do
    case Integer.parse(s) do
      {n, ""} -> n * 60
      _ -> 0
    end
  end

  # ── ISO format helpers ──

  defp expand_short_iso(s) do
    s =
      case Regex.run(~r/^(\d{4})T(.+)$/, s) do
        [_, year, time] ->
          "#{year}-01-01T#{time}"

        _ ->
          case Regex.run(~r/^(\d{4})-(\d{2})T(.+)$/, s) do
            [_, year, month, time] -> "#{year}-#{month}-01T#{time}"
            _ -> s
          end
      end

    normalize_time(s)
  end

  defp normalize_time(s) do
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
      String.ends_with?(time, "Z") ->
        String.split_at(time, -1)

      byte_size(time) >= 6 and String.at(time, -6) in ["+", "-"] ->
        String.split_at(time, -6)

      true ->
        {time, ""}
    end
  end
end
