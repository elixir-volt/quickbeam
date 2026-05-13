defmodule QuickBEAM.VM.Runtime.Date do
  @moduledoc "JS `Date` built-in: constructor, parsing, formatting, and all get/set prototype methods."

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Heap

  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.{Invocation, JSThrow}

  alias QuickBEAM.VM.Interpreter.Values.Coercion

  @epoch_gs 719_528 * 86_400
  @time_clip_limit 8_640_000_000_000_000

  defp coerce_date_value(obj) do
    prim = Coercion.to_primitive(obj)

    case prim do
      s when is_binary(s) -> parse_date_string(s)
      n when is_number(n) -> trunc(n)
      true -> 1
      false -> 0
      nil -> 0
      :undefined -> :nan
      {:symbol, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a number")
      {:symbol, _, _} -> JSThrow.type_error!("Cannot convert a Symbol value to a number")
      :nan -> :nan
      :infinity -> :nan
      :neg_infinity -> :nan
      _ -> :nan
    end
  end

  @doc "Implements Date.prototype[Symbol.toPrimitive](hint)."
  def symbol_to_primitive(this, args) do
    unless match?({:obj, _}, this) do
      JSThrow.type_error!("Date.prototype[Symbol.toPrimitive] requires that 'this' be an Object")
    end

    hint = List.first(args, "default")

    try_first =
      case hint do
        "string" -> :string
        "default" -> :string
        "number" -> :number
        _ -> JSThrow.type_error!("Invalid hint: " <> Values.stringify(hint))
      end

    ordinary_to_primitive(this, try_first)
  end

  defp ordinary_to_primitive({:obj, _} = obj, :string) do
    case try_method(obj, "toString") do
      nil ->
        case try_method(obj, "valueOf") do
          nil -> JSThrow.type_error!("Cannot convert object to primitive value")
          val -> val
        end

      val ->
        val
    end
  end

  defp ordinary_to_primitive({:obj, _} = obj, :number) do
    case try_method(obj, "valueOf") do
      nil ->
        case try_method(obj, "toString") do
          nil -> JSThrow.type_error!("Cannot convert object to primitive value")
          val -> val
        end

      val ->
        val
    end
  end

  defp try_method(obj, method_name) do
    method = QuickBEAM.VM.ObjectModel.Get.get(obj, method_name)

    if QuickBEAM.VM.Builtin.callable?(method) do
      result = Invocation.invoke_with_receiver(method, [], obj)

      case result do
        {:obj, _} -> nil
        _ -> result
      end
    else
      nil
    end
  end

  # ── Constructor ──

  @doc "Returns Date.prototype method names declared by this module."
  def proto_property_names do
    ~w(getTime valueOf getFullYear getMonth getDate getHours getMinutes getSeconds getMilliseconds getUTCFullYear getUTCMonth getUTCDate getUTCDay getUTCHours getUTCMinutes getUTCSeconds getUTCMilliseconds getDay getTimezoneOffset setTime setFullYear setMonth setDate setHours setMinutes setSeconds setMilliseconds setUTCHours setUTCMinutes setUTCSeconds setUTCMilliseconds setUTCFullYear setUTCMonth setUTCDate toISOString toJSON toString toDateString toTimeString toUTCString toLocaleTimeString toLocaleDateString toLocaleString toTemporalInstant)
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor(_args, nil) do
    ms = System.system_time(:millisecond)

    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%a %b %d %Y %H:%M:%S GMT+0000 (UTC)")
      _ -> "Invalid Date"
    end
  end

  def constructor(args, this) do
    ms =
      case args do
        [] ->
          System.system_time(:millisecond)

        [:nan] ->
          :nan

        [:infinity] ->
          :nan

        [:neg_infinity] ->
          :nan

        [val] when is_number(val) ->
          if abs(val) > 8.64e15, do: :nan, else: trunc(val)

        [true] ->
          1

        [false] ->
          0

        [nil] ->
          :nan

        [:undefined] ->
          :nan

        [s] when is_binary(s) ->
          parse_date_string(s)

        [{:obj, ref} = obj] ->
          case Heap.get_obj(ref, %{}) do
            %{date_ms() => ms} -> ms
            _ -> coerce_date_value(obj)
          end

        [_ | _] when length(args) >= 2 ->
          local_from_components(args)

        _ ->
          System.system_time(:millisecond)
      end

    construct_date_object(this, ms)
  end

  defp construct_date_object({:obj, ref} = object, ms) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, proto()) ->
        Heap.put_obj(ref, Map.put(map, date_ms(), ms))
        object

      _ ->
        new_date_object(ms)
    end
  end

  defp construct_date_object(_this, ms), do: new_date_object(ms)

  defp new_date_object(ms) do
    Heap.wrap(%{
      date_ms() => ms,
      proto() => QuickBEAM.VM.Runtime.Constructors.class_proto("Date")
    })
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
  proto("getUTCMonth", do: dt_field(this, :month, &(&1 - 1)))
  proto("getUTCDate", do: dt_field(this, :day))
  proto("getUTCDay", do: with_dt(this, &(Date.day_of_week(&1) |> rem(7))))
  proto("getUTCHours", do: dt_field(this, :hour))
  proto("getUTCMinutes", do: dt_field(this, :minute))
  proto("getUTCSeconds", do: dt_field(this, :second))
  proto("getUTCMilliseconds", do: with_ms(this, &rem(&1, 1000)))
  proto("getDay", do: with_dt(this, &(Date.day_of_week(&1) |> rem(7))))

  proto("getTimezoneOffset",
    do:
      (
        ms = get_ms(this)
        if ms == :nan, do: :nan, else: tz_offset_minutes()
      )
  )

  # ── Setters ──

  proto("setTime",
    do:
      (
        get_ms(this)
        put_ms(this, QuickBEAM.VM.Runtime.to_number(arg(args, 0, :undefined)))
      )
  )

  proto("setFullYear", do: set_full_year(this, args))
  proto("setMonth", do: set_month(this, args))
  proto("setDate", do: set_date_field(this, args))
  proto("setHours", do: set_time_fields(this, [:hour, :minute, :second, :ms], args))
  proto("setMinutes", do: set_time_fields(this, [:minute, :second, :ms], args))
  proto("setSeconds", do: set_time_fields(this, [:second, :ms], args))
  proto("setMilliseconds", do: set_time_fields(this, [:ms], args))
  proto("setUTCHours", do: set_time_fields(this, [:hour, :minute, :second, :ms], args))
  proto("setUTCMinutes", do: set_time_fields(this, [:minute, :second, :ms], args))
  proto("setUTCSeconds", do: set_time_fields(this, [:second, :ms], args))
  proto("setUTCMilliseconds", do: set_time_fields(this, [:ms], args))
  proto("setUTCFullYear", do: set_full_year(this, args))
  proto("setUTCMonth", do: set_month(this, args))
  proto("setUTCDate", do: set_date_field(this, args))

  # ── Formatting ──

  proto("toISOString", do: to_iso_string(this))
  proto("toJSON", do: to_json(this, args))

  proto("toString",
    do: fmt_dt(this, &Calendar.strftime(&1, "%a %b %d %Y %H:%M:%S GMT+0000 (UTC)"))
  )

  proto("toDateString", do: fmt_dt(this, &Calendar.strftime(&1, "%a %b %d %Y")))
  proto("toTimeString", do: fmt_dt(this, &Calendar.strftime(&1, "%H:%M:%S GMT+0000")))
  proto("toUTCString", do: fmt_dt(this, &Calendar.strftime(&1, "%a, %d %b %Y %H:%M:%S GMT")))
  proto("toLocaleTimeString", do: fmt_local(this, "%I:%M:%S %p"))
  proto("toLocaleDateString", do: fmt_local(this, "%m/%d/%Y"))
  proto("toLocaleString", do: fmt_local(this, "%m/%d/%Y, %I:%M:%S %p"))
  proto("toTemporalInstant", do: to_temporal_instant(this))

  # ── Internal: ms ↔ DateTime ──

  defp get_ms({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{date_ms() => ms} -> ms
      _ -> throw({:js_throw, Heap.make_error("this is not a Date object", "TypeError")})
    end
  end

  defp get_ms({:symbol, _}),
    do: throw({:js_throw, Heap.make_error("this is not a Date object", "TypeError")})

  defp get_ms({:symbol, _, _}),
    do: throw({:js_throw, Heap.make_error("this is not a Date object", "TypeError")})

  defp get_ms({:bigint, _}),
    do: throw({:js_throw, Heap.make_error("this is not a Date object", "TypeError")})

  defp get_ms(val)
       when val in [nil, :undefined] or is_number(val) or is_binary(val) or
              is_boolean(val) or is_atom(val),
       do: throw({:js_throw, Heap.make_error("this is not a Date object", "TypeError")})

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

  defp to_iso_string(this) do
    ms = get_ms(this)

    case ms_to_dt(ms) do
      nil ->
        throw({:js_throw, Heap.make_error("Invalid time value", "RangeError")})

      dt ->
        millis = rem(abs(trunc(ms)), 1000)

        iso_year(dt.year) <>
          Calendar.strftime(dt, "-%m-%dT%H:%M:%S") <>
          "." <> String.pad_leading(Integer.to_string(millis), 3, "0") <> "Z"
    end
  end

  defp iso_year(year) when year >= 0 and year <= 9999,
    do: String.pad_leading(Integer.to_string(year), 4, "0")

  defp iso_year(year) when year < 0,
    do: "-" <> String.pad_leading(Integer.to_string(abs(year)), 6, "0")

  defp iso_year(year),
    do: "+" <> String.pad_leading(Integer.to_string(year), 6, "0")

  defp to_json(this, _args) do
    tv = QuickBEAM.VM.Interpreter.Values.Coercion.to_primitive(this, "number")

    non_finite? =
      case tv do
        n when is_number(n) -> false
        :nan -> true
        :infinity -> true
        :neg_infinity -> true
        _ -> false
      end

    if non_finite? do
      nil
    else
      to_iso_fn = QuickBEAM.VM.ObjectModel.Get.get(this, "toISOString")

      if QuickBEAM.VM.Builtin.callable?(to_iso_fn) do
        QuickBEAM.VM.Invocation.invoke_with_receiver(to_iso_fn, [], this)
      else
        throw({:js_throw, Heap.make_error("toISOString is not a function", "TypeError")})
      end
    end
  end

  defp to_temporal_instant({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{date_ms() => ms} when is_number(ms) ->
        Heap.wrap(%{"epochNanoseconds" => {:bigint, trunc(ms) * 1_000_000}})

      %{date_ms() => _} ->
        JSThrow.range_error!("Invalid time value")

      _ ->
        JSThrow.type_error!("this is not a Date object")
    end
  end

  defp to_temporal_instant(_this), do: JSThrow.type_error!("this is not a Date object")

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
    val = if abs(ms) > 8.64e15, do: :nan, else: trunc(ms)
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), date_ms(), val))
    val
  end

  defp put_ms({:obj, ref}, :nan) do
    Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), date_ms(), :nan))
    :nan
  end

  defp put_ms(_, _), do: :nan

  defp set_full_year(this, []), do: put_ms(this, :nan)

  defp set_full_year(this, args) do
    ms = get_ms(this)
    coerced_args = Enum.map(args, &to_num/1)
    base_ms = if ms == :nan, do: 0, else: ms

    case ms_to_dt(base_ms) do
      nil ->
        :nan

      dt ->
        year = Enum.at(coerced_args, 0, 0)
        month = if length(args) >= 2, do: Enum.at(coerced_args, 1, 0), else: dt.month - 1
        day = if length(args) >= 3, do: Enum.at(coerced_args, 2, 1), else: dt.day
        time_ms = rem(trunc(base_ms), 86_400_000)

        new_ms = make_date(year, month, day, time_ms)
        put_ms(this, new_ms)
    end
  rescue
    _ -> :nan
  end

  defp make_date(year, month, day, time_ms)
       when year in [:nan, :infinity, :neg_infinity] or
              month in [:nan, :infinity, :neg_infinity] or
              day in [:nan, :infinity, :neg_infinity] or
              time_ms in [:nan, :infinity, :neg_infinity],
       do: :nan

  defp make_date(year, month, day, time_ms) do
    y = trunc(year)
    m = trunc(month)
    d = trunc(day)

    {adj_year, adj_month} =
      if m >= 0 do
        {y + div(m, 12), rem(m, 12)}
      else
        full = div(m - 11, 12)
        {y + full, m - full * 12}
      end

    base = Date.new!(trunc(adj_year), adj_month + 1, 1)
    target = Date.add(base, d - 1)
    days_from_epoch = Date.diff(target, ~D[1970-01-01])
    result = days_from_epoch * 86_400_000 + time_ms
    if abs(result) > 8.64e15, do: :nan, else: result
  rescue
    _ -> :nan
  end

  defp set_date_field(this, []), do: put_ms(this, :nan)

  defp set_date_field(this, args) do
    ms = get_ms(this)
    coerced = Enum.map(args, &to_num/1)
    if ms == :nan, do: :nan, else: do_set_date_field(this, coerced, ms)
  end

  defp do_set_date_field(this, coerced, base_ms) do
    case ms_to_dt(base_ms) do
      nil ->
        :nan

      dt ->
        day = Enum.at(coerced, 0, dt.day)
        time_ms = rem(trunc(base_ms), 86_400_000)
        make_date(dt.year, dt.month - 1, day, time_ms) |> then(&put_ms(this, &1))
    end
  rescue
    _ -> :nan
  end

  defp set_month(this, []), do: put_ms(this, :nan)

  defp set_month(this, args) do
    ms = get_ms(this)
    coerced_args = Enum.map(args, &to_num/1)
    if ms == :nan, do: :nan, else: do_set_month(this, coerced_args, ms)
  end

  defp do_set_month(this, coerced_args, base_ms) do
    case ms_to_dt(base_ms) do
      nil ->
        :nan

      dt ->
        month = Enum.at(coerced_args, 0, 0)
        day = if length(coerced_args) >= 2, do: Enum.at(coerced_args, 1, 1), else: dt.day
        time_ms = rem(trunc(base_ms), 86_400_000)
        make_date(dt.year, month, day, time_ms) |> then(&put_ms(this, &1))
    end
  rescue
    _ -> :nan
  end

  defp to_num(val) when is_number(val), do: val
  defp to_num(:nan), do: :nan
  defp to_num(:infinity), do: :infinity
  defp to_num(:neg_infinity), do: :neg_infinity
  defp to_num(nil), do: 0
  defp to_num(:undefined), do: :nan
  defp to_num(true), do: 1
  defp to_num(false), do: 0
  defp to_num(val), do: QuickBEAM.VM.Runtime.to_number(val)

  defp set_time_fields(this, _possible_fields, []), do: put_ms(this, :nan)

  defp set_time_fields(this, possible_fields, args) do
    ms = get_ms(this)
    coerced = Enum.map(args, &to_num/1)
    if ms == :nan, do: :nan, else: do_set_time_fields(this, possible_fields, coerced, ms)
  end

  defp do_set_time_fields(this, possible_fields, args, base_ms) do
    case ms_to_dt(base_ms) do
      nil ->
        :nan

      dt ->
        base_hour = dt.hour
        base_min = dt.minute
        base_sec = dt.second
        base_ms_part = rem(trunc(base_ms), 1000)

        {h, m, s, ms_val} =
          Enum.zip(possible_fields, args)
          |> Enum.reduce({base_hour, base_min, base_sec, base_ms_part}, fn
            {:hour, v}, {_, mi, se, ms} -> {to_num(v), mi, se, ms}
            {:minute, v}, {ho, _, se, ms} -> {ho, to_num(v), se, ms}
            {:second, v}, {ho, mi, _, ms} -> {ho, mi, to_num(v), ms}
            {:ms, v}, {ho, mi, se, _} -> {ho, mi, se, to_num(v)}
          end)

        day_ms = trunc(base_ms) - rem(trunc(base_ms), 86_400_000)

        new_ms =
          day_ms + trunc(h) * 3_600_000 + trunc(m) * 60_000 + trunc(s) * 1000 + trunc(ms_val)

        time_clip(put_ms(this, new_ms))
    end
  rescue
    _ -> :nan
  end

  defp time_clip(:nan), do: :nan
  defp time_clip(ms) when is_number(ms) and abs(ms) > 8.64e15, do: put_ms_nan()
  defp time_clip(ms), do: ms

  defp put_ms_nan, do: :nan

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
    if args == [] do
      :nan
    else
      with {:ok, components} <- extract_components(args) do
        utc_ms(components)
      end
    end
  end

  defp local_from_components(args) do
    with {:ok, components} <- extract_components(args),
         ms when is_integer(ms) <- utc_ms_raw(components) do
      offset_ms = tz_offset_minutes() * 60_000

      if abs(ms) >= @time_clip_limit - 86_400_000 do
        time_clip_value(ms + offset_ms)
      else
        time_clip_value(ms)
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
      |> Enum.map(&to_num/1)

    if Enum.any?(vals, &(&1 in [:nan, :infinity, :neg_infinity])) do
      :nan
    else
      y = trunc(Enum.at(vals, 0, 0) * 1.0)
      year = if y >= 0 and y <= 99, do: 1900 + y, else: y

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
        time_clip_value(time_ms)
    end
  end

  defp utc_ms_raw({year, month, day, hour, minute, second, ms_part}) do
    year = year + div(month - 1, 12)
    month = rem(rem(month - 1, 12) + 12, 12) + 1

    case make_day(year, month) do
      :nan ->
        :nan

      base_days ->
        day_f = (day - 1 + base_days) * 1.0

        (((day_f * 24 + hour * 1.0) * 60 + minute * 1.0) * 60_000 +
           second * 1000.0 + ms_part * 1.0)
        |> trunc()
    end
  end

  defp time_clip_value(ms) when is_number(ms) and abs(ms) > @time_clip_limit, do: :nan
  defp time_clip_value(ms) when is_number(ms), do: trunc(ms)
  defp time_clip_value(_), do: :nan

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

  @doc "Helper for js `date` built-in: constructor, parsing, formatting, and all get/set prototype methods."
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

    case parse_extended_iso_utc(with_tz) do
      {:ok, ms} ->
        if ms != :nan and has_time and not has_explicit_tz,
          do: ms + tz_offset_minutes() * 60_000,
          else: ms

      :error ->
        case safe_rfc3339_parse(with_tz) do
          {:ok, ms} ->
            if has_time and not has_explicit_tz,
              do: ms + tz_offset_minutes() * 60_000,
              else: ms

          :error ->
            :miss
        end
    end
  end

  defp parse_extended_iso_utc("-000000-" <> _), do: {:ok, :nan}

  defp parse_extended_iso_utc(s) do
    pattern =
      ~r/^([+-]\d{6}|\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?Z$/

    case Regex.run(pattern, s) do
      [_, year, month, day, hour, minute, second, ms] ->
        extended_iso_ms(year, month, day, hour, minute, second, ms)

      [_, year, month, day, hour, minute, second] ->
        extended_iso_ms(year, month, day, hour, minute, second, "0")

      [_, year, month, day, hour, minute] ->
        extended_iso_ms(year, month, day, hour, minute, "0", "0")

      _ ->
        :error
    end
  end

  defp extended_iso_ms(year, month, day, hour, minute, second, ms) do
    value =
      utc_ms(
        {String.to_integer(year), String.to_integer(month), String.to_integer(day),
         String.to_integer(hour), String.to_integer(minute), String.to_integer(second),
         (ms || "0") |> String.pad_trailing(3, "0") |> String.to_integer()}
      )

    if value == :nan, do: :error, else: {:ok, value}
  rescue
    _ -> :error
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
          cond do
            byte_size(a) == 4 ->
              parse_ymd(a, b, c)

            Map.has_key?(@month_names, String.downcase(String.slice(a, 0..2))) ->
              parse_mdy(a, b, c)

            true ->
              parse_dmy(a, b, c)
          end

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

  defp parse_dmy(day_str, month_str, year_str) do
    with {day, ""} <- Integer.parse(day_str),
         month when is_integer(month) <-
           Map.get(@month_names, String.downcase(String.slice(month_str, 0..2))),
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
