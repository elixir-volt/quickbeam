defmodule QuickBEAM.VM.PromiseState do
  @moduledoc false

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter

  def resolved(val), do: make_promise(:resolved, val)
  def rejected(val), do: make_promise(:rejected, val)

  def resolve(ref, state, val) do
    Heap.put_obj(ref, promise_obj(state, val, ref))

    for {on_fulfilled, on_rejected, child_ref} <- pop_waiters(ref) do
      handler =
        case state do
          :resolved -> on_fulfilled
          :rejected -> on_rejected
        end

      handler = if callable?(handler), do: handler, else: fn v -> v end
      Heap.enqueue_microtask({:resolve, child_ref, handler, val})
    end
  end

  def drain_microtasks do
    case Heap.dequeue_microtask() do
      nil ->
        :ok

      {:resolve, child_ref, callback, val} ->
        result =
          try do
            Interpreter.invoke_callback(callback, [val])
          catch
            {:js_throw, err} -> {:rejected, err}
          end

        case result do
          {:rejected, err} -> resolve(child_ref, :rejected, err)
          result_val -> resolve_or_chain(child_ref, result_val)
        end

        drain_microtasks()
    end
  end

  # ── Internal ──

  defp make_promise(state, val) do
    ref = make_ref()
    Heap.put_obj(ref, promise_obj(state, val, ref))
    {:obj, ref}
  end

  defp promise_obj(state, val, ref) do
    %{
      promise_state() => state,
      promise_value() => val,
      "then" => then_fn(ref),
      "catch" => catch_fn(ref)
    }
  end

  defp pending_child do
    ref = make_ref()
    Heap.put_obj(ref, promise_obj(:pending, nil, ref))
    ref
  end

  defp then_fn(promise_ref) do
    {:builtin, "then",
     fn args, _this ->
       on_fulfilled = Enum.at(args, 0)
       on_rejected = Enum.at(args, 1)

       case Heap.get_obj(promise_ref, %{}) do
         %{promise_state() => state, promise_value() => val}
         when state in [:resolved, :rejected] ->
           handler = if state == :resolved, do: on_fulfilled, else: on_rejected

           if callable?(handler) do
             child_ref = pending_child()
             Heap.enqueue_microtask({:resolve, child_ref, handler, val})
             {:obj, child_ref}
           else
             make_promise(state, val)
           end

         %{promise_state() => :pending} ->
           child_ref = pending_child()
           waiters = Heap.get_promise_waiters(promise_ref)

           Heap.put_promise_waiters(promise_ref, [
             {on_fulfilled, on_rejected, child_ref} | waiters
           ])

           {:obj, child_ref}

         _ ->
           resolved(:undefined)
       end
     end}
  end

  defp catch_fn(promise_ref) do
    {:builtin, "catch",
     fn args, this ->
       {:builtin, _, cb} = then_fn(promise_ref)
       cb.([nil, List.first(args)], this)
     end}
  end

  defp resolve_or_chain(child_ref, {:obj, r}) do
    case Heap.get_obj(r, %{}) do
      %{promise_state() => :resolved, promise_value() => v} ->
        resolve(child_ref, :resolved, v)

      %{promise_state() => :rejected, promise_value() => v} ->
        resolve(child_ref, :rejected, v)

      %{promise_state() => :pending} ->
        waiters = Heap.get_promise_waiters(r)

        Heap.put_promise_waiters(r, [
          {fn v -> resolve(child_ref, :resolved, v) end, nil, child_ref} | waiters
        ])

      _ ->
        resolve(child_ref, :resolved, {:obj, r})
    end
  end

  defp resolve_or_chain(child_ref, val), do: resolve(child_ref, :resolved, val)

  defp callable?(nil), do: false
  defp callable?(:undefined), do: false
  defp callable?(_), do: true

  defp pop_waiters(ref) do
    waiters = Heap.get_promise_waiters(ref)
    Heap.delete_promise_waiters(ref)
    waiters
  end
end
