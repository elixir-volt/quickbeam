defmodule QuickBEAM.VM.Host.Web.Timers do
  @moduledoc "setTimeout, clearTimeout, setInterval, clearInterval builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  require QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap.Caches
  alias QuickBEAM.VM.Interpreter

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    QuickBEAM.VM.Builtin.build_methods do
      method "setTimeout" do
        set_timeout(args, this)
      end

      method "clearTimeout" do
        clear_timeout(args, this)
      end

      method "setInterval" do
        set_interval(args, this)
      end

      method "clearInterval" do
        clear_interval(args, this)
      end
    end
  end

  # ── Timer queue (stored in process dictionary) ──

  defp next_id do
    id = Caches.get_timer_next_id()
    Caches.put_timer_next_id(id + 1)
    id
  end

  defp now_ms, do: :erlang.monotonic_time(:millisecond)

  defp enqueue_timer(id, type, callback, delay_ms, repeat_ms) do
    fire_at = now_ms() + max(delay_ms, 0)
    timer = %{id: id, type: type, callback: callback, fire_at: fire_at, repeat_ms: repeat_ms}
    Caches.put_timer_queue(Caches.get_timer_queue() ++ [timer])
  end

  defp dequeue_timer_id(id) do
    cancel_timer_id(id)
    Caches.put_timer_queue(Enum.reject(Caches.get_timer_queue(), &(&1.id == id)))
  end

  defp cancel_timer_id(id),
    do: Caches.put_cancelled_timer_ids(MapSet.put(cancelled_timer_ids(), id))

  defp cancelled_timer_ids, do: Caches.get_cancelled_timer_ids()
  defp cancelled_timer?(id), do: MapSet.member?(cancelled_timer_ids(), id)

  @doc "Runs due timers from the process-local timer queue."
  def drain_timers do
    queue = Caches.get_timer_queue()
    now = now_ms()

    {ready, pending} = Enum.split_with(queue, fn timer -> timer.fire_at <= now end)

    Caches.put_timer_queue(pending)

    if ready != [] do
      Enum.each(ready, fn timer ->
        unless cancelled_timer?(timer.id) do
          try do
            Interpreter.invoke_callback(timer.callback, [])
          catch
            {:js_throw, _} -> :ok
          end

          if timer.type == :interval and not cancelled_timer?(timer.id) do
            enqueue_timer(timer.id, :interval, timer.callback, timer.repeat_ms, timer.repeat_ms)
          end
        end
      end)

      QuickBEAM.VM.Promise.drain_microtasks()
      true
    else
      false
    end
  end

  @doc "Returns milliseconds until the next queued timer should run."
  def next_timer_delay_ms do
    case Caches.get_timer_queue() do
      [] ->
        nil

      queue ->
        now = now_ms()
        min_fire = Enum.min_by(queue, & &1.fire_at).fire_at
        max(0, min_fire - now)
    end
  end

  # ── Builtin implementations ──

  @doc "Adds a timeout callback to the process-local timer queue."
  def enqueue_timeout(callback, delay_ms) do
    id = next_id()
    enqueue_timer(id, :timeout, callback, delay_ms, nil)
    id
  end

  defp set_timeout([callback | rest], _) do
    delay =
      case rest do
        [n | _] when is_number(n) -> trunc(n)
        _ -> 0
      end

    id = next_id()
    enqueue_timer(id, :timeout, callback, delay, nil)
    id * 1.0
  end

  defp clear_timeout([id | _], _) do
    int_id = coerce_timer_id(id)
    if int_id, do: dequeue_timer_id(int_id)
    :undefined
  end

  defp set_interval([callback | rest], _) do
    delay =
      case rest do
        [n | _] when is_number(n) -> trunc(n)
        _ -> 0
      end

    id = next_id()
    enqueue_timer(id, :interval, callback, delay, max(delay, 0))
    id * 1.0
  end

  defp clear_interval([id | _], _) do
    int_id = coerce_timer_id(id)
    if int_id, do: dequeue_timer_id(int_id)
    :undefined
  end

  defp coerce_timer_id(n) when is_float(n), do: trunc(n)
  defp coerce_timer_id(n) when is_integer(n), do: n
  defp coerce_timer_id(_), do: nil
end
