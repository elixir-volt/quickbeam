defmodule QuickBEAM.VM.Runtime.Web.Navigator do
  @moduledoc "navigator object with navigator.locks for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow, PromiseState}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.StructuredClone

  def bindings do
    %{"navigator" => build_navigator()}
  end

  defp build_navigator do
    build_object do
      val("userAgent", "QuickBEAM/1.0")
      val("platform", "BEAM")
      val("language", "en-US")
      val("onLine", true)
      val("locks", build_locks())
    end
  end

  defp build_locks do
    build_object do
      method "request" do
        case args do
          [name | rest] ->
            {mode, if_available, callback} = parse_lock_opts(rest)
            name_str = to_string(name)
            do_lock_request(name_str, mode, if_available, callback)

          _ ->
            JSThrow.type_error!("navigator.locks.request requires a name argument")
        end
      end

      method "query" do
        result =
          try do
            QuickBEAM.LockManager.query()
          rescue
            _ -> %{held: [], pending: []}
          catch
            _, _ -> %{held: [], pending: []}
          end

        held_list = Map.get(result, :held, [])
        pending_list = Map.get(result, :pending, [])

        held_js = Enum.map(held_list, fn lock ->
          Heap.wrap(%{"name" => lock.name, "mode" => lock.mode})
        end)

        pending_js = Enum.map(pending_list, fn req ->
          Heap.wrap(%{"name" => req.name, "mode" => req.mode})
        end)

        query_result = Heap.wrap(%{
          "held" => held_js,
          "pending" => pending_js
        })

        PromiseState.resolved(query_result)
      end
    end
  end

  defp parse_lock_opts(rest) do
    case rest do
      [opts, cb | _] when not is_function(opts) ->
        mode = case Get.get(opts, "mode") do
          m when is_binary(m) -> m
          _ -> "exclusive"
        end

        if_avail = Get.get(opts, "ifAvailable") == true
        {mode, if_avail, cb}

      [cb | _] ->
        {"exclusive", false, cb}

      [] ->
        JSThrow.type_error!("navigator.locks.request requires a callback")
    end
  end

  defp do_lock_request(name, mode, if_available, callback) do
    caller_pid = self()

    grant_result =
      try do
        QuickBEAM.LocksAPI.request_lock([name, mode, if_available], caller_pid)
      rescue
        _ -> "holder_down"
      catch
        _, _ -> "holder_down"
      end

    case grant_result do
      "granted" ->
        lock_obj = Heap.wrap(%{"name" => name, "mode" => mode})

        result =
          try do
            QuickBEAM.VM.Interpreter.invoke_callback(callback, [lock_obj])
          catch
            {:js_throw, err} ->
              QuickBEAM.LocksAPI.release_lock([name], caller_pid)
              throw({:js_throw, err})
          end

        QuickBEAM.LocksAPI.release_lock([name], caller_pid)
        PromiseState.resolved(await_if_promise(result))

      "not_available" ->
        lock_null = nil
        result =
          try do
            QuickBEAM.VM.Interpreter.invoke_callback(callback, [lock_null])
          catch
            {:js_throw, err} -> throw({:js_throw, err})
          end

        PromiseState.resolved(await_if_promise(result))

      _ ->
        PromiseState.rejected(Heap.make_error("Lock request failed", "DOMException"))
    end
  end

  defp await_if_promise(val) do
    case val do
      {:obj, ref} ->
        import QuickBEAM.VM.Heap.Keys
        case Heap.get_obj(ref, %{}) do
          %{promise_state() => :resolved, promise_value() => v} -> v
          %{promise_state() => :rejected, promise_value() => v} ->
            throw({:js_throw, v})
          %{promise_state() => :pending} ->
            # Block waiting for resolution
            wait_for_promise(ref, 5000)
          _ -> val
        end
      _ -> val
    end
  end

  defp wait_for_promise(ref, timeout) do
    import QuickBEAM.VM.Heap.Keys

    # Drain microtasks repeatedly until settled
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop(ref, deadline)
  end

  defp wait_loop(ref, deadline) do
    import QuickBEAM.VM.Heap.Keys
    QuickBEAM.VM.PromiseState.drain_microtasks()

    case Heap.get_obj(ref, %{}) do
      %{promise_state() => :resolved, promise_value() => v} -> v
      %{promise_state() => :rejected, promise_value() => v} -> throw({:js_throw, v})
      _ ->
        now = System.monotonic_time(:millisecond)
        if now >= deadline do
          JSThrow.type_error!("Lock callback timed out")
        else
          Process.sleep(1)
          wait_loop(ref, deadline)
        end
    end
  end
end
