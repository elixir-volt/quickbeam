defmodule QuickBEAM.VM.Runtime.Web.ConsoleAPI do
  @moduledoc "Enhanced console object with Logger-based output for BEAM mode."

  require Logger

  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]

  alias QuickBEAM.VM.{Heap, Runtime}

  @timer_key :qb_console_timers
  @count_key :qb_console_counts

  def bindings do
    %{"console" => console_object()}
  end

  defp console_object do
    object do
      method "log" do
        msg = format_args(args)
        Logger.info(msg)
        :undefined
      end

      method "info" do
        msg = format_args(args)
        Logger.info(msg)
        :undefined
      end

      method "warn" do
        msg = format_args(args)
        Logger.warning(msg)
        :undefined
      end

      method "error" do
        msg = format_args(args)
        Logger.error(msg)
        :undefined
      end

      method "debug" do
        msg = format_args(args)
        Logger.info(msg)
        :undefined
      end

      method "trace" do
        msg = format_args(args)
        Logger.debug("Trace: #{msg}")
        :undefined
      end

      method "assert" do
        case args do
          [cond_val | rest] ->
            falsy =
              cond_val == false or cond_val == nil or cond_val == :undefined or cond_val == 0 or
                cond_val == ""

            if falsy do
              msg = if rest == [], do: "", else: format_args(rest)
              Logger.error("Assertion failed: #{msg}")
            end

          _ ->
            Logger.error("Assertion failed:")
        end

        :undefined
      end

      method "time" do
        label =
          case args do
            [l | _] when is_binary(l) -> l
            _ -> "default"
          end

        timers = Process.get(@timer_key, %{})
        Process.put(@timer_key, Map.put(timers, label, System.monotonic_time(:millisecond)))
        :undefined
      end

      method "timeEnd" do
        label =
          case args do
            [l | _] when is_binary(l) -> l
            _ -> "default"
          end

        timers = Process.get(@timer_key, %{})
        now = System.monotonic_time(:millisecond)

        case Map.get(timers, label) do
          nil ->
            Logger.warning("Timer '#{label}' does not exist")

          start ->
            elapsed = now - start
            Logger.info("#{label}: #{elapsed}ms")
            Process.put(@timer_key, Map.delete(timers, label))
        end

        :undefined
      end

      method "timeLog" do
        label =
          case args do
            [l | _] when is_binary(l) -> l
            _ -> "default"
          end

        timers = Process.get(@timer_key, %{})
        now = System.monotonic_time(:millisecond)

        case Map.get(timers, label) do
          nil ->
            Logger.warning("Timer '#{label}' does not exist")

          start ->
            elapsed = now - start
            Logger.info("#{label}: #{elapsed}ms")
        end

        :undefined
      end

      method "count" do
        label =
          case args do
            [l | _] when is_binary(l) -> l
            [:undefined | _] -> "default"
            [nil | _] -> "default"
            _ -> "default"
          end

        counts = Process.get(@count_key, %{})
        n = Map.get(counts, label, 0) + 1
        Process.put(@count_key, Map.put(counts, label, n))
        Logger.info("#{label}: #{n}")
        :undefined
      end

      method "countReset" do
        label =
          case args do
            [l | _] when is_binary(l) -> l
            _ -> "default"
          end

        counts = Process.get(@count_key, %{})

        if Map.has_key?(counts, label) do
          Process.put(@count_key, Map.put(counts, label, 0))
        else
          Logger.warning("Count for '#{label}' does not exist")
        end

        :undefined
      end

      method "dir" do
        obj = arg(args, 0, :undefined)
        json = inspect_js_value(obj)
        Logger.info(json)
        :undefined
      end

      method "table" do
        obj = arg(args, 0, :undefined)
        Logger.info(inspect_js_value(obj))
        :undefined
      end

      method "group" do
        label = format_args(args)
        Logger.info("group: #{label}")
        :undefined
      end

      method "groupCollapsed" do
        label = format_args(args)
        Logger.info("group: #{label}")
        :undefined
      end

      method "groupEnd" do
        Logger.info("groupEnd")
        :undefined
      end

      method "clear" do
        :undefined
      end

      method "profile" do
        :undefined
      end

      method "profileEnd" do
        :undefined
      end
    end
  end

  defp format_args([]), do: ""
  defp format_args(args), do: Enum.map_join(args, " ", &Runtime.stringify/1)

  defp inspect_js_value(val) do
    case val do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          m when is_map(m) ->
            m
            |> Enum.filter(fn {k, _v} -> is_binary(k) end)
            |> Enum.map_join(",\n  ", fn {k, v} -> "\"#{k}\": #{Runtime.stringify(v)}" end)
            |> then(fn content -> "{\n  #{content}\n}" end)

          _ ->
            Runtime.stringify(val)
        end

      _ ->
        Runtime.stringify(val)
    end
  end
end
