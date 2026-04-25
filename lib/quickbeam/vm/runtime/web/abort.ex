defmodule QuickBEAM.VM.Runtime.Web.Abort do
  @moduledoc "AbortController and AbortSignal builtins for BEAM mode."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Get, Put}

  def bindings do
    %{"AbortController" => register("AbortController", &build_abort_controller/2)}
  end

  defp build_abort_controller(_args, _this) do
    signal = Heap.wrap(%{"aborted" => false, "reason" => :undefined})

    Heap.wrap(%{
      "signal" => signal,
      "abort" =>
        {:builtin, "abort",
         fn args, this ->
           sig = Get.get(this, "signal")
           reason = List.first(args, :undefined)
           Put.put(sig, "aborted", true)
           Put.put(sig, "reason", reason)
           :undefined
         end}
    })
  end

  defp register(name, constructor) do
    ctor = {:builtin, name, constructor}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end
end
