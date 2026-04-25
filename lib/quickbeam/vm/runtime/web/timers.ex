defmodule QuickBEAM.VM.Runtime.Web.Timers do
  @moduledoc "setTimeout, clearTimeout, setInterval, clearInterval builtins for BEAM mode."

  alias QuickBEAM.VM.Heap.Caches
  alias QuickBEAM.VM.Interpreter

  def bindings do
    %{
      "setTimeout" => {:builtin, "setTimeout", &set_timeout/2},
      "clearTimeout" => {:builtin, "clearTimeout", &clear_timeout/2},
      "setInterval" => {:builtin, "setInterval", &set_interval/2},
      "clearInterval" => {:builtin, "clearInterval", &clear_interval/2}
    }
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
    Caches.put_timer_queue(Enum.reject(Caches.get_timer_queue(), &(&1.id == id)))
  end

  def drain_timers do
    queue = Caches.get_timer_queue()
    now = now_ms()

    {ready, pending} = Enum.split_with(queue, fn timer -> timer.fire_at <= now end)

    Caches.put_timer_queue(pending)

    if ready != [] do
      Enum.each(ready, fn timer ->
        try do
          Interpreter.invoke_callback(timer.callback, [])
        catch
          {:js_throw, _} -> :ok
        end

        # Re-enqueue intervals
        if timer.type == :interval do
          enqueue_timer(timer.id, :interval, timer.callback, timer.repeat_ms, timer.repeat_ms)
        end
      end)

      QuickBEAM.VM.PromiseState.drain_microtasks()
      true
    else
      false
    end
  end

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
