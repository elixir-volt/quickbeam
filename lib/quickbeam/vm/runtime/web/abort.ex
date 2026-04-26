defmodule QuickBEAM.VM.Runtime.Web.Abort do
  @moduledoc "AbortController and AbortSignal builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, constructor: 2, object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.Web.{Callback, StateRef}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{
      "AbortController" => WebAPIs.register("AbortController", &build_abort_controller/2),
      "AbortSignal" => build_abort_signal_static()
    }
  end

  defp build_abort_controller(_args, _this) do
    signal = build_signal()

    object do
      prop("signal", signal)

      method "abort" do
        sig = Get.get(this, "signal")
        reason = arg(args, 0, :undefined)
        actual_reason = if reason == :undefined, do: make_abort_error(), else: reason
        do_abort(sig, actual_reason)
        :undefined
      end
    end
  end

  defp build_abort_signal_static do
    ctor = constructor("AbortSignal", fn _args, _this -> build_signal() end)

    Heap.put_ctor_static(
      ctor,
      "abort",
      {:builtin, "abort",
       fn args, _ ->
         reason = arg(args, 0, :undefined)
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
         ms = args |> arg(0, 0) |> coerce_number()
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
         signals_val = arg(args, 0, [])

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

  @doc "Builds an AbortSignal object backed by VM heap state."
  def build_signal do
    listeners_ref = StateRef.new(%{list: []})

    object do
      prop("aborted", false)
      prop("reason", :undefined)

      method "addEventListener" do
        [type, callback] = argv(args, [nil, nil])

        if to_string(type) == "abort" do
          store_listeners(listeners_ref, load_listeners(listeners_ref) ++ [callback])
        end

        :undefined
      end

      method "removeEventListener" do
        [type, callback] = argv(args, [nil, nil])

        if to_string(type) == "abort" do
          listeners = Enum.reject(load_listeners(listeners_ref), &(&1 == callback))
          store_listeners(listeners_ref, listeners)
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
    |> tap(fn signal ->
      {:obj, ref} = signal

      Heap.update_obj(ref, %{}, fn m ->
        Map.put(m, "__listeners_ref__", {:obj, listeners_ref})
      end)
    end)
  end

  @doc "Transitions an AbortSignal into the aborted state and dispatches listeners."
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

              Enum.each(listeners, &Callback.safe_invoke(&1, []))

            _ ->
              :ok
          end
        end

      _ ->
        :ok
    end
  end

  @doc "Registers an abort listener on an AbortSignal state object."
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
    case StateRef.get(ref, %{}) do
      %{list: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp store_listeners(ref, listeners) do
    StateRef.put(ref, %{list: listeners})
  end

  @doc "Creates the standard abort error value."
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
