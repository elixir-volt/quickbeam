defmodule QuickBEAM.BeamVM.Runtime.Date do
  alias QuickBEAM.BeamVM.Heap

  def constructor(args) do
    ms = case args do
      [] -> System.system_time(:millisecond)
      [val | _] when is_number(val) -> trunc(val)
      [s | _] when is_binary(s) ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
          _ -> :nan
        end
      _ -> System.system_time(:millisecond)
    end

    ref = make_ref()
    Heap.put_obj(ref, %{"__date_ms__" => ms})
    {:obj, ref}
  end

  def proto_property("getTime"), do: {:builtin, "getTime", fn _, this -> get_ms(this) end}
  def proto_property("valueOf"), do: {:builtin, "valueOf", fn _, this -> get_ms(this) end}

  def proto_property("getFullYear"), do: {:builtin, "getFullYear", fn _, this ->
    {{y, _, _}, _} = utc(this); y
  end}

  def proto_property("getMonth"), do: {:builtin, "getMonth", fn _, this ->
    {{_, m, _}, _} = utc(this); m - 1
  end}

  def proto_property("getDate"), do: {:builtin, "getDate", fn _, this ->
    {{_, _, d}, _} = utc(this); d
  end}

  def proto_property("getHours"), do: {:builtin, "getHours", fn _, this ->
    {_, {h, _, _}} = utc(this); h
  end}

  def proto_property("getMinutes"), do: {:builtin, "getMinutes", fn _, this ->
    {_, {_, m, _}} = utc(this); m
  end}

  def proto_property("getSeconds"), do: {:builtin, "getSeconds", fn _, this ->
    {_, {_, _, s}} = utc(this); s
  end}

  def proto_property("getMilliseconds"), do: {:builtin, "getMilliseconds", fn _, this ->
    rem(get_ms(this), 1000)
  end}

  def proto_property("toISOString"), do: {:builtin, "toISOString", fn _, this ->
    ms = get_ms(this)
    {{y, m, d}, {h, min, s}} = :calendar.system_time_to_universal_time(ms, :millisecond)
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [y, m, d, h, min, s, rem(ms, 1000)])
    |> IO.iodata_to_binary()
  end}

  def proto_property("toJSON"), do: proto_property("toISOString")

  def proto_property("toString"), do: {:builtin, "toString", fn _, this ->
    ms = get_ms(this)
    {{y, m, d}, {h, min, s}} = :calendar.system_time_to_universal_time(ms, :millisecond)
    "#{y}-#{m}-#{d}T#{h}:#{min}:#{s}Z"
  end}

  def proto_property(_), do: :undefined

  def static_now do
    {:builtin, "now", fn _ -> System.system_time(:millisecond) end}
  end

  defp get_ms({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__date_ms__" => ms} -> ms
      _ -> :nan
    end
  end
  defp get_ms(_), do: :nan

  defp utc(this) do
    :calendar.system_time_to_universal_time(get_ms(this), :millisecond)
  end
end
