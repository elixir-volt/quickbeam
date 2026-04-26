defmodule QuickBEAM.VM.Runtime.Web.Abort do
  @moduledoc "AbortController and AbortSignal builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{
      "AbortController" => WebAPIs.register("AbortController", &build_abort_controller/2),
      "AbortSignal" => build_abort_signal_static()
    }
  end

  defp build_abort_controller(_args, _this) do
    signal = build_signal()

    Heap.wrap(
      build_methods do
        val("signal", signal)

        method "abort" do
          sig = Get.get(this, "signal")
          reason = List.first(args, :undefined)
          actual_reason = if reason == :undefined, do: make_abort_error(), else: reason
          do_abort(sig, actual_reason)
          :undefined
        end
      end
    )
  end

  defp build_abort_signal_static do
    ctor = {:builtin, "AbortSignal", fn _args, _this -> build_signal() end}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)

    Heap.put_ctor_static(
      ctor,
      "abort",
      {:builtin, "abort",
       fn args, _ ->
         reason = List.first(args, :undefined)
         actual_reason = if reason == :undefined, do: make_abort_error(), else: reason
         signal = build_signal()
         do_abort(signal, actual_reason)
         signal
       end}
    )

    Heap.put_ctor_static(
      ctor,
      "timeout",
      {:builtin, "timeout",
       fn args, _ ->
         ms = args |> List.first(0) |> coerce_number()
         signal = build_signal()

         abort_callback =
           {:builtin, "__abort_timeout__",
            fn _args, _this ->
              do_abort(signal, make_timeout_error())
              :undefined
            end}

         QuickBEAM.VM.Runtime.Web.Timers.enqueue_timeout(abort_callback, ms)
         signal
       end}
    )

    Heap.put_ctor_static(
      ctor,
      "any",
      {:builtin, "any",
       fn args, _ ->
         signals_val = List.first(args, [])

         signals =
           case signals_val do
             {:obj, _} -> Heap.to_list(signals_val)
             list when is_list(list) -> list
             _ -> []
           end

         combined = build_signal()

         Enum.each(signals, fn sig ->
           if Get.get(sig, "aborted") == true do
             reason = Get.get(sig, "reason")
             do_abort(combined, reason)
           else
             add_abort_listener(sig, fn reason ->
               do_abort(combined, reason)
             end)
           end
         end)

         combined
       end}
    )

    ctor
  end

  def build_signal do
    listeners_ref = make_ref()
    Heap.put_obj(listeners_ref, %{list: []})

    Heap.wrap(
      build_methods do
        val("aborted", false)
        val("reason", :undefined)

        method "addEventListener" do
          [type | rest] = args ++ [nil, nil]
          callback = List.first(rest)

          if to_string(type) == "abort" do
            existing = load_listeners(listeners_ref)
            store_listeners(listeners_ref, existing ++ [callback])
          end

          :undefined
        end

        method "removeEventListener" do
          [type, callback | _] = args ++ [nil, nil]

          if to_string(type) == "abort" do
            existing = load_listeners(listeners_ref)
            store_listeners(listeners_ref, Enum.reject(existing, &(&1 == callback)))
          end

          :undefined
        end

        method "throwIfAborted" do
          if Get.get(this, "aborted") == true do
            reason = Get.get(this, "reason")
            JSThrow.error!("Signal aborted")
            throw({:js_throw, reason})
          end

          :undefined
        end
      end
    )
    |> tap(fn signal ->
      {:obj, ref} = signal
      Heap.update_obj(ref, %{}, fn m ->
        Map.put(m, "__listeners_ref__", {:obj, listeners_ref})
      end)
    end)
  end

  def do_abort(signal, reason) do
    case signal do
      {:obj, _} ->
        aborted = Get.get(signal, "aborted")

        if aborted != true do
          Put.put(signal, "aborted", true)
          Put.put(signal, "reason", reason)

          case Get.get(signal, "__listeners_ref__") do
            {:obj, lref} ->
              listeners = load_listeners(lref)

              Enum.each(listeners, fn cb ->
                try do
                  Invocation.invoke_with_receiver(cb, [], :undefined)
                rescue
                  _ -> :ok
                catch
                  _, _ -> :ok
                end
              end)

            _ ->
              :ok
          end
        end

      _ ->
        :ok
    end
  end

  def add_abort_listener(signal, fun) do
    cb =
      {:builtin, "__abort_listener__",
       fn _args, _this ->
         reason = Get.get(signal, "reason")
         fun.(reason)
         :undefined
       end}

    case Get.get(signal, "__listeners_ref__") do
      {:obj, lref} ->
        existing = load_listeners(lref)
        store_listeners(lref, existing ++ [cb])

      _ ->
        :ok
    end
  end

  defp load_listeners(ref) do
    case Heap.get_obj(ref, %{}) do
      %{list: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp store_listeners(ref, listeners) do
    Heap.put_obj(ref, %{list: listeners})
  end

  def make_abort_error do
    make_dom_exception("The operation was aborted.", "AbortError")
  end

  defp make_timeout_error do
    make_dom_exception("The operation timed out.", "TimeoutError")
  end

  defp make_dom_exception(message, name) do
    alias QuickBEAM.VM.Runtime.Web.Events
    Events.make_dom_exception(message, name)
  end

  defp coerce_number(n) when is_integer(n), do: n
  defp coerce_number(n) when is_float(n), do: trunc(n)
  defp coerce_number(_), do: 0
end
