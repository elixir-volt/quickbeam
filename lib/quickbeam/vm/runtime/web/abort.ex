defmodule QuickBEAM.VM.Runtime.Web.Abort do
  @moduledoc "AbortController and AbortSignal builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1, build_object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{"AbortController" => WebAPIs.register("AbortController", &build_abort_controller/2)}
  end

  defp build_abort_controller(_args, _this) do
    signal = build_object do
      val("aborted", false)
      val("reason", :undefined)
    end

    Heap.wrap(
      build_methods do
        val("signal", signal)

        method "abort" do
          sig = Get.get(this, "signal")
          reason = List.first(args, :undefined)
          Put.put(sig, "aborted", true)
          Put.put(sig, "reason", reason)
          :undefined
        end
      end
    )
  end
end
