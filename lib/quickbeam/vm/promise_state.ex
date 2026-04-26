defmodule QuickBEAM.VM.PromiseState do
  @moduledoc "Promise lifecycle: create resolved/rejected promises, chain `.then`/`.catch`/`.finally`, and flush microtasks."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Builtin, only: [arg: 3]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.Interpreter

  @doc "Creates or returns a resolved Promise state value."
  def resolved(val), do: make_promise(:resolved, val)
  @doc "Creates or returns a rejected Promise state value."
  def rejected(val), do: make_promise(:rejected, val)

  @doc "Implements Promise.prototype.then state transitions."
  def promise_then(args, {:obj, promise_ref}), do: then_impl(args, promise_ref)
  def promise_then(_args, _this), do: resolved(:undefined)

  @doc "Implements Promise.prototype.catch state transitions."
  def promise_catch(args, this), do: promise_then([nil, arg(args, 0, nil)], this)

  @doc "Implements Promise.prototype.finally state transitions."
  def promise_finally([callback | _], {:obj, promise_ref}) do
    then_impl(
      [
        fn value ->
          run_finally(callback)
          value
        end,
        fn reason ->
          run_finally(callback)
          throw({:js_throw, reason})
        end
      ],
      promise_ref
    )
  end

  def promise_finally(_args, _this), do: resolved(:undefined)

  @doc "Resolves a Promise state and drains queued reactions."
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

  @doc "Runs queued microtasks until the queue is empty."
  def drain_microtasks do
    case Heap.dequeue_microtask() do
      nil ->
        :ok

      {:resolve, nil, callback, val} ->
        # queueMicrotask-style: fire and forget, errors silently discarded
        try do
          Interpreter.invoke_callback(callback, [val])
        catch
          {:js_throw, _} -> :ok
        end

        drain_microtasks()

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
    base = %{
      promise_state() => state,
      promise_value() => val,
      "then" => then_fn(ref),
      "catch" => catch_fn(ref)
    }

    case promise_proto() do
      nil -> base
      proto -> Map.put(base, "__proto__", proto)
    end
  end

  defp pending_child do
    ref = make_ref()
    Heap.put_obj(ref, promise_obj(:pending, nil, ref))
    ref
  end

  defp then_fn(promise_ref) do
    {:builtin, "then", fn args, _this -> then_impl(args, promise_ref) end}
  end

  defp catch_fn(promise_ref) do
    {:builtin, "catch", fn args, _this -> then_impl([nil, arg(args, 0, nil)], promise_ref) end}
  end

  defp then_impl(args, promise_ref) do
    on_fulfilled = arg(args, 0, nil)
    on_rejected = arg(args, 1, nil)

    case Heap.get_obj(promise_ref, %{}) do
      %{promise_state() => state, promise_value() => val} when state in [:resolved, :rejected] ->
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
  end

  defp run_finally(callback) do
    if callable?(callback) do
      Interpreter.invoke_callback(callback, [])
    else
      :undefined
    end
  end

  defp promise_proto, do: Runtime.global_class_proto("Promise")

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
