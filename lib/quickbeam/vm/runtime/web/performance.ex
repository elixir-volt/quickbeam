defmodule QuickBEAM.VM.Runtime.Web.Performance do
  @moduledoc "performance object builtin for BEAM mode, including mark/measure/getEntries."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, constructor: 2, object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.Get

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{"performance" => performance_object()}
  end

  defp performance_object do
    time_origin_us = :erlang.system_time(:microsecond)
    time_origin_ms = time_origin_us / 1000.0

    entries_ref = make_ref()
    Heap.put_obj(entries_ref, %{list: []})

    perf_mark_ctor = make_perf_mark_ctor()
    perf_measure_ctor = make_perf_measure_ctor()

    object do
      prop("timeOrigin", time_origin_ms)

      method "now" do
        (:erlang.system_time(:microsecond) - time_origin_us) / 1000.0
      end

      method "mark" do
        name = args |> arg(0, nil) |> to_string()
        opts = arg(args, 1, nil)

        now = (:erlang.system_time(:microsecond) - time_origin_us) / 1000.0

        {start_time, detail} =
          case opts do
            {:obj, _} ->
              st =
                case Get.get(opts, "startTime") do
                  :undefined -> now
                  nil -> now
                  n when is_number(n) -> n * 1.0
                  _ -> now
                end

              det =
                case Get.get(opts, "detail") do
                  :undefined -> nil
                  v -> v
                end

              {st, det}

            _ ->
              {now, nil}
          end

        mark = make_perf_entry("mark", name, start_time, 0, detail, perf_mark_ctor)
        entries = load_entries(entries_ref)
        store_entries(entries_ref, entries ++ [mark])
        mark
      end

      method "measure" do
        name = args |> arg(0, "unnamed") |> to_string()
        entries = load_entries(entries_ref)
        rest = Enum.drop(args, 1)

        now = (:erlang.system_time(:microsecond) - time_origin_us) / 1000.0

        {start_time, end_time, detail} =
          case rest do
            [{:obj, _} = opts | _] ->
              start_opt = Get.get(opts, "start")
              end_opt = Get.get(opts, "end")
              dur_opt = Get.get(opts, "duration")

              det =
                case Get.get(opts, "detail") do
                  :undefined -> nil
                  v -> v
                end

              {resolved_start, resolved_end} =
                resolve_measure_opts(start_opt, end_opt, dur_opt, entries, now)

              {resolved_start, resolved_end, det}

            [start_mark | [end_mark | _]] when start_mark != nil and start_mark != :undefined ->
              st = resolve_mark_name(start_mark, entries, now, "start")

              et =
                case end_mark do
                  nil -> now
                  :undefined -> now
                  em -> resolve_mark_name(em, entries, now, "end")
                end

              {st, et, nil}

            [start_mark | _] when start_mark != nil and start_mark != :undefined ->
              st = resolve_mark_name(start_mark, entries, now, "start")
              {st, now, nil}

            _ ->
              {0.0, now, nil}
          end

        duration = end_time - start_time

        measure =
          make_perf_entry("measure", name, start_time, duration, detail, perf_measure_ctor)

        store_entries(entries_ref, entries ++ [measure])
        measure
      end

      method "getEntries" do
        Heap.wrap(load_entries(entries_ref))
      end

      method "getEntriesByType" do
        type = args |> arg(0, nil) |> to_string()

        result =
          entries_ref
          |> load_entries()
          |> Enum.filter(fn e -> Get.get(e, "entryType") == type end)

        Heap.wrap(result)
      end

      method "getEntriesByName" do
        name = args |> arg(0, nil) |> to_string()
        type_filter = arg(args, 1, nil)

        result =
          entries_ref
          |> load_entries()
          |> Enum.filter(fn e ->
            name_match = Get.get(e, "name") == name

            type_match =
              case type_filter do
                nil -> true
                :undefined -> true
                t -> Get.get(e, "entryType") == to_string(t)
              end

            name_match and type_match
          end)

        Heap.wrap(result)
      end

      method "clearMarks" do
        name_filter = arg(args, 0, nil)

        updated =
          entries_ref
          |> load_entries()
          |> Enum.reject(fn e ->
            if Get.get(e, "entryType") == "mark" do
              case name_filter do
                nil -> true
                :undefined -> true
                n -> Get.get(e, "name") == to_string(n)
              end
            else
              false
            end
          end)

        store_entries(entries_ref, updated)
        :undefined
      end

      method "clearMeasures" do
        name_filter = arg(args, 0, nil)

        updated =
          entries_ref
          |> load_entries()
          |> Enum.reject(fn e ->
            if Get.get(e, "entryType") == "measure" do
              case name_filter do
                nil -> true
                :undefined -> true
                n -> Get.get(e, "name") == to_string(n)
              end
            else
              false
            end
          end)

        store_entries(entries_ref, updated)
        :undefined
      end

      method "toJSON" do
        Heap.wrap(%{"timeOrigin" => time_origin_ms})
      end
    end
  end

  defp make_perf_mark_ctor do
    constructor("PerformanceMark", fn _args, _this -> :undefined end)
  end

  defp make_perf_measure_ctor do
    constructor("PerformanceMeasure", fn _args, _this -> :undefined end)
  end

  defp make_perf_entry(entry_type, name, start_time, duration, detail, ctor) do
    proto = Heap.get_class_proto(ctor)

    object do
      prop("name", name)
      prop("entryType", entry_type)
      prop("startTime", start_time)
      prop("duration", duration)
      prop("detail", detail)
      prop("constructor", ctor)
      prop("__proto__", proto)

      method "toJSON" do
        det = Get.get(this, "detail")

        Heap.wrap(%{
          "name" => Get.get(this, "name"),
          "entryType" => Get.get(this, "entryType"),
          "startTime" => Get.get(this, "startTime"),
          "duration" => Get.get(this, "duration"),
          "detail" => det
        })
      end
    end
  end

  defp resolve_measure_opts(start_opt, end_opt, dur_opt, entries, now) do
    case {start_opt, end_opt, dur_opt} do
      {:undefined, :undefined, :undefined} ->
        {0.0, now}

      {:undefined, :undefined, nil} ->
        {0.0, now}

      {s, :undefined, :undefined} when s != :undefined ->
        st = resolve_time_opt(s, entries, "start")
        {st, now}

      {s, :undefined, nil} when s != :undefined ->
        st = resolve_time_opt(s, entries, "start")
        {st, now}

      {:undefined, e, :undefined} when e != :undefined ->
        et = resolve_time_opt(e, entries, "end")
        {0.0, et}

      {:undefined, e, nil} when e != :undefined ->
        et = resolve_time_opt(e, entries, "end")
        {0.0, et}

      {s, e, :undefined} when s != :undefined and e != :undefined ->
        st = resolve_time_opt(s, entries, "start")
        et = resolve_time_opt(e, entries, "end")
        {st, et}

      {s, e, nil} when s != :undefined and e != :undefined ->
        st = resolve_time_opt(s, entries, "start")
        et = resolve_time_opt(e, entries, "end")
        {st, et}

      {s, :undefined, d} when s != :undefined and d != :undefined and d != nil ->
        st = resolve_time_opt(s, entries, "start")
        dur = coerce_number(d)
        {st, st + dur}

      {s, nil, d} when s != :undefined and d != :undefined and d != nil ->
        st = resolve_time_opt(s, entries, "start")
        dur = coerce_number(d)
        {st, st + dur}

      {:undefined, e, d} when e != :undefined and d != :undefined and d != nil ->
        et = resolve_time_opt(e, entries, "end")
        dur = coerce_number(d)
        {et - dur, et}

      {nil, e, d} when e != :undefined and d != :undefined and d != nil ->
        et = resolve_time_opt(e, entries, "end")
        dur = coerce_number(d)
        {et - dur, et}

      _ ->
        st =
          if start_opt != :undefined and start_opt != nil,
            do: resolve_time_opt(start_opt, entries, "start"),
            else: 0.0

        et =
          if end_opt != :undefined and end_opt != nil,
            do: resolve_time_opt(end_opt, entries, "end"),
            else: now

        {st, et}
    end
  end

  defp resolve_time_opt(opt, _entries, _role) when is_number(opt), do: opt * 1.0

  defp resolve_time_opt(opt, entries, role) when is_binary(opt) do
    resolve_mark_name(opt, entries, 0.0, role)
  end

  defp resolve_time_opt({:obj, _} = _obj, _entries, _role), do: 0.0
  defp resolve_time_opt(_, _entries, _role), do: 0.0

  defp resolve_mark_name(name_val, entries, _default, role) when is_binary(name_val) do
    case Enum.filter(entries, fn e -> Get.get(e, "name") == name_val end) do
      [] ->
        JSThrow.error!("The mark '#{name_val}' does not exist")

      matches ->
        mark = List.last(matches)
        st = Get.get(mark, "startTime")
        dur = Get.get(mark, "duration")

        case role do
          "end" -> coerce_number(st) + coerce_number(dur)
          _ -> coerce_number(st)
        end
    end
  end

  defp resolve_mark_name(name_val, entries, default, role) do
    resolve_mark_name(to_string(name_val), entries, default, role)
  end

  defp coerce_number(n) when is_float(n), do: n
  defp coerce_number(n) when is_integer(n), do: n * 1.0
  defp coerce_number(_), do: 0.0

  defp load_entries(entries_ref) do
    case Heap.get_obj(entries_ref, %{}) do
      %{list: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp store_entries(entries_ref, entries) do
    Heap.put_obj(entries_ref, %{list: entries})
  end
end
