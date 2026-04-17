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

    Heap.put_obj(ref, %{
      "__date_ms__" => ms,
      "getTime" => {:builtin, "getTime", fn _, _ -> ms end},
      "getFullYear" => {:builtin, "getFullYear", fn _, _ ->
        {{y, _, _}, _} = :calendar.system_time_to_universal_time(ms, :millisecond)
        y
      end},
      "getMonth" => {:builtin, "getMonth", fn _, _ ->
        {{_, m, _}, _} = :calendar.system_time_to_universal_time(ms, :millisecond)
        m - 1
      end},
      "getDate" => {:builtin, "getDate", fn _, _ ->
        {{_, _, d}, _} = :calendar.system_time_to_universal_time(ms, :millisecond)
        d
      end},
      "toISOString" => {:builtin, "toISOString", fn _, _ ->
        {{y, m, d}, {h, min, s}} = :calendar.system_time_to_universal_time(ms, :millisecond)
        :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
          [y, m, d, h, min, s, rem(ms, 1000)])
        |> IO.iodata_to_binary()
      end},
      "toString" => {:builtin, "toString", fn _, _ ->
        {{y, m, d}, {h, min, s}} = :calendar.system_time_to_universal_time(ms, :millisecond)
        "#{y}-#{m}-#{d}T#{h}:#{min}:#{s}Z"
      end},
      "valueOf" => {:builtin, "valueOf", fn _, _ -> ms end}
    })

    {:obj, ref}
  end

  def static_now do
    {:builtin, "now", fn _ -> System.system_time(:millisecond) end}
  end
end
