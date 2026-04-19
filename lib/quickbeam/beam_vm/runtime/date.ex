defmodule QuickBEAM.BeamVM.Runtime.Date do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys
  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap

  @epoch_gregorian_seconds 62_167_219_200

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
          padded = args ++ List.duplicate(0, 7)
          y = Enum.at(padded, 0, 0)
          year = if is_number(y) and y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y || 0)
          month = trunc(Enum.at(padded, 1, 0)) + 1
          day = trunc(Enum.at(padded, 2, 1))
          day = if day == 0, do: 1, else: day
          hour = trunc(Enum.at(padded, 3, 0))
          minute = trunc(Enum.at(padded, 4, 0))
          second = trunc(Enum.at(padded, 5, 0))
          ms_part = trunc(Enum.at(padded, 6, 0))
          utc = gregorian_to_ms(year, month, day, hour, minute, second, ms_part)
          if utc == :nan, do: :nan, else: utc - local_tz_offset_minutes() * 60_000

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
    padded = args ++ List.duplicate(0, 7)
    y = Enum.at(padded, 0, 0)
    year = if is_number(y) and y >= 0 and y <= 99, do: 1900 + trunc(y), else: trunc(y || 0)

    gregorian_to_ms(
      year,
      trunc(Enum.at(padded, 1, 0)) + 1,
      max(1, trunc(Enum.at(padded, 2, 1))),
      trunc(Enum.at(padded, 3, 0)),
      trunc(Enum.at(padded, 4, 0)),
      trunc(Enum.at(padded, 5, 0)),
      trunc(Enum.at(padded, 6, 0))
    )
  end

  # ── Getters ──

  proto "getTime" do
    get_ms(this)
  end

  proto "valueOf" do
    get_ms(this)
  end

  proto "getFullYear" do
    with_dt(this, & &1.year)
  end

  proto "getMonth" do
    with_dt(this, &(&1.month - 1))
  end

  proto "getDate" do
    with_dt(this, & &1.day)
  end

  proto "getHours" do
    with_dt(this, & &1.hour)
  end

  proto "getMinutes" do
    with_dt(this, & &1.minute)
  end

  proto "getSeconds" do
    with_dt(this, & &1.second)
  end

  proto "getMilliseconds" do
    with_ms(this, &rem(&1, 1000))
  end

  proto "getUTCFullYear" do
    with_dt(this, & &1.year)
  end

  # JS: 0=Sun..6=Sat. Elixir day_of_week: 1=Mon..7=Sun. rem(7) maps 7→0.
  proto "getDay" do
    with_dt(this, &(Date.day_of_week(DateTime.to_date(&1)) |> rem(7)))
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

  # ── Formatting (all via Calendar.strftime) ──

  proto "toISOString" do
    with_dt(
      this,
      fn dt ->
        Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <>
          ".#{String.pad_leading(Integer.to_string(rem(get_ms(this), 1000)), 3, "0")}Z"
      end,
      "Invalid Date"
    )
  end

  proto "toJSON" do
    {:builtin, _, cb} = proto_property("toISOString")
    cb.(args, this)
  end

  proto "toString" do
    fmt(this, "%Y-%m-%dT%H:%M:%SZ")
  end

  proto "toDateString" do
    fmt(this, "%a %b %d %Y")
  end

  proto "toTimeString" do
    fmt(this, "%H:%M:%S GMT+0000")
  end

  proto "toUTCString" do
    fmt(this, "%a, %d %b %Y %H:%M:%S GMT")
  end

  proto "toLocaleDateString" do
    fmt(this, "%m/%d/%Y")
  end

  proto "toLocaleTimeString" do
    fmt(this, "%H:%M:%S")
  end

  proto "toLocaleString" do
    fmt(this, "%m/%d/%Y, %H:%M:%S")
  end

  # ── Helpers ──

  defp get_ms({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{date_ms() => ms} -> ms
      _ -> :nan
    end
  end

  defp get_ms(_), do: :nan

  defp to_dt(this) do
    case get_ms(this) do
      ms when is_number(ms) ->
        case DateTime.from_unix(trunc(ms), :millisecond) do
          {:ok, dt} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp with_dt(this, fun, default \\ :nan) do
    case to_dt(this) do
      nil -> default
      dt -> fun.(dt)
    end
  end

  defp with_ms(this, fun) do
    case get_ms(this) do
      ms when is_number(ms) -> fun.(trunc(ms))
      _ -> :nan
    end
  end

  defp fmt(this, pattern),
    do: with_dt(this, &Calendar.strftime(&1, pattern), "Invalid Date")

  defp put_ms({:obj, ref}, ms) when is_number(ms) do
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), date_ms(), trunc(ms)))
    trunc(ms)
  end

  defp put_ms(_, _), do: :nan

  defp set_field(this, field, value) do
    with_dt(this, fn dt ->
      fields =
        Map.put(
          %{
            year: dt.year,
            month: dt.month,
            day: dt.day,
            hour: dt.hour,
            minute: dt.minute,
            second: dt.second
          },
          field,
          trunc(value)
        )

      with {:ok, ndt} <-
             NaiveDateTime.new(
               fields.year,
               fields.month,
               fields.day,
               fields.hour,
               fields.minute,
               fields.second
             ),
           {:ok, new_dt} <- DateTime.from_naive(ndt, "Etc/UTC") do
        put_ms(this, DateTime.to_unix(new_dt, :millisecond))
      else
        _ -> :nan
      end
    end)
  end

  defp tz_offset_minutes do
    utc_s = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    local_s = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
    div(utc_s - local_s, 60)
  end

  defp gregorian_to_ms(year, month, day, hour, minute, second, ms) do
    if year >= 0 do
      gs = :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})
      (gs - @epoch_gregorian_seconds) * 1000 + ms
    else
      days = days_from_epoch(year, month, day)
      time_s = hour * 3600 + minute * 60 + second
      days * 86_400_000 + time_s * 1000 + ms
    end
  rescue
    _ -> :nan
  end

  defp days_from_epoch(year, month, day) do
    # Days from 1970-01-01 to the given date (negative for dates before epoch)
    # Using the algorithm from Howard Hinnant's date library
    y = if month <= 2, do: year - 1, else: year
    era = div(if(y >= 0, do: y, else: y - 399), 400)
    yoe = y - era * 400
    doy = div(153 * (month + (if month > 2, do: -3, else: 9)) + 2, 5) + day - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146097 + doe - 719468
  end

  # ── Date.parse ──
  # Normalizes JS date string formats to something DateTime.from_iso8601 can handle.
  # JS accepts: YYYY, YYYY-MM, YYYY-MM-DD, full ISO 8601, +/-YYYYYY expanded years.

  def parse_date_string(s) when is_binary(s) do
    s = String.trim(s)
    if s == "", do: :nan, else: do_parse(s)
  end

  def parse_date_string(_), do: :nan

  defp do_parse(s) do
    s_expanded = expand_short_iso(s)
    has_explicit_tz = String.contains?(s, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, s)
    has_time = String.contains?(s_expanded, "T")

    with :miss <- try_iso_datetime(s_expanded, has_explicit_tz, has_time),
         :miss <- try_iso_date(s),
         :miss <- try_informal(s),
         :miss <- try_partial(s) do
      :nan
    end
  end

  defp try_iso_datetime(s, has_explicit_tz, has_time) do
    with_tz = cond do
      String.contains?(s, "Z") -> s
      Regex.match?(~r/[+-]\d{2}:\d{2}$/, s) -> s
      String.contains?(s, "T") -> s <> "Z"
      true -> s
    end

    case DateTime.from_iso8601(with_tz) do
      {:ok, dt, _} ->
        ms = DateTime.to_unix(dt, :millisecond)
        if has_time and not has_explicit_tz do
          ms - local_tz_offset_minutes() * 60_000
        else
          ms
        end

      _ ->
        :miss
    end
  end

  defp try_iso_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> gregorian_to_ms(d.year, d.month, d.day, 0, 0, 0, 0)
      _ -> :miss
    end
  end

  defp try_partial(s) do
    case parse_partial(s) do
      :nan -> :miss
      ms -> ms
    end
  end

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
        _ -> s
      end

    case Regex.run(~r/^(\w{3})\s+(\d{1,2})\s+(\d{4})\s*(.*)$/i, s) do
      [_, month_str, day_str, year_str, time_tz] ->
        month = Map.get(@month_names, String.downcase(String.slice(month_str, 0..2)))
        if month do
          {day, ""} = Integer.parse(day_str)
          {year, ""} = Integer.parse(year_str)
          {hour, minute, second, tz_offset} = parse_informal_time(String.trim(time_tz))
          ms = gregorian_to_ms(year, month, day, hour, minute, second, 0)
          if tz_offset != nil do
            ms - tz_offset * 60_000
          else
            ms - local_tz_offset_minutes() * 60_000
          end
        else
          :miss
        end
      _ -> :miss
    end
  end

  defp parse_informal_time(""), do: {0, 0, 0, nil}

  defp parse_informal_time(s) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(.*)$/, s) do
      [_, h, m, sec, tz] ->
        {String.to_integer(h), String.to_integer(m),
         (if sec != "", do: String.to_integer(sec), else: 0),
         (if tz == "", do: nil, else: parse_tz_offset(String.trim(tz)))}
      _ -> {0, 0, 0, nil}
    end
  end

  defp local_tz_offset_minutes do
    utc = :calendar.universal_time()
    local = :calendar.local_time()
    div(:calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc), 60)
  end

  defp parse_tz_offset(""), do: 0
  defp parse_tz_offset("Z"), do: 0
  defp parse_tz_offset("GMT" <> rest), do: parse_tz_offset(rest)
  defp parse_tz_offset("UTC" <> rest), do: parse_tz_offset(rest)
  defp parse_tz_offset("+" <> o), do: parse_tz_num(o)
  defp parse_tz_offset("-" <> o), do: -parse_tz_num(o)
  defp parse_tz_offset(_), do: 0

  defp parse_tz_num(s) when byte_size(s) == 4 do
    String.to_integer(String.slice(s, 0..1)) * 60 + String.to_integer(String.slice(s, 2..3))
  end
  defp parse_tz_num(s) do
    case Integer.parse(s) do
      {n, ""} -> n * 60
      _ -> 0
    end
  end

  defp expand_short_iso(s) do
    s = case Regex.run(~r/^(\d{4})T(.+)$/, s) do
      [_, year, time] -> "#{year}-01-01T#{time}"
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
        padded = case String.split(time_part, ":") do
          [h, m] -> "#{h}:#{m}:00"
          _ -> time_part
        end
        date <> "T" <> padded <> tz
      _ -> s
    end
  end

  defp split_time_tz(time) do
    cond do
      String.ends_with?(time, "Z") -> {String.trim_trailing(time, "Z"), "Z"}
      Regex.match?(~r/[+-]\d{2}:\d{2}$/, time) ->
        {String.slice(time, 0..-7//1), String.slice(time, -6..-1//1)}
      true -> {time, ""}
    end
  end

  defp ensure_offset(s) do
    s = normalize_time(s)

    cond do
      String.contains?(s, "Z") -> s
      String.contains?(s, "+") and String.contains?(s, "T") -> s
      String.contains?(s, "T") -> s <> "Z"
      true -> s
    end
  end

  defp normalize_time(s) do
    case String.split(s, "T", parts: 2) do
      [date, time] ->
        {time_part, tz} = split_tz(time)

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

  defp split_tz(time) do
    cond do
      String.contains?(time, "Z") ->
        [t, _] = String.split(time, "Z", parts: 2)
        {t, "Z"}

      String.match?(time, ~r/[+-]\d{2}:\d{2}$/) ->
        {String.slice(time, 0..-7//1), String.slice(time, -6..-1//1)}

      true ->
        {time, ""}
    end
  end

  defp parse_partial(s) do
    # Strip leading +/- for expanded years
    {sign, digits} =
      case s do
        "+" <> r -> {1, r}
        "-" <> r -> {-1, r}
        r -> {1, r}
      end

    case String.split(digits, "-", parts: 3) do
      # YYYY or YYYYYY
      [year_str] ->
        case Integer.parse(year_str) do
          {year, ""} -> gregorian_to_ms(sign * year, 1, 1, 0, 0, 0, 0)
          _ -> :nan
        end

      # YYYY-MM
      [year_str, month_str] ->
        with {year, ""} <- Integer.parse(year_str),
             {month, ""} <- Integer.parse(month_str) do
          gregorian_to_ms(sign * year, month, 1, 0, 0, 0, 0)
        else
          _ -> :nan
        end

      _ ->
        :nan
    end
  end
end
