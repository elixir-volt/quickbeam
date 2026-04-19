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
        [] -> System.system_time(:millisecond)
        [val | _] when is_number(val) -> trunc(val)
        [s | _] when is_binary(s) -> parse_date_string(s)
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
    gs = :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})
    (gs - @epoch_gregorian_seconds) * 1000 + ms
  rescue
    _ -> :nan
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
    # Try full ISO 8601 first (handles YYYY-MM-DDTHH:MM:SSZ and variants)
    case DateTime.from_iso8601(ensure_offset(s)) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt, :millisecond)

      _ ->
        # Try date-only via Date.from_iso8601 (handles YYYY-MM-DD)
        case Date.from_iso8601(s) do
          {:ok, d} ->
            gregorian_to_ms(d.year, d.month, d.day, 0, 0, 0, 0)

          _ ->
            # Try bare year (YYYY) or year-month (YYYY-MM) or expanded year (+/-YYYYYY)
            parse_partial(s)
        end
    end
  end

  defp ensure_offset(s) do
    cond do
      String.contains?(s, "Z") -> s
      String.contains?(s, "+") and String.contains?(s, "T") -> s
      String.contains?(s, "T") -> s <> "Z"
      true -> s
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
