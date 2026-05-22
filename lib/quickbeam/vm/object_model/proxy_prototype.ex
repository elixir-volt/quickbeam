defmodule QuickBEAM.VM.ObjectModel.ProxyPrototype do
  @moduledoc "Proxy [[GetPrototypeOf]] dispatch."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{JSThrow, Value}
  alias QuickBEAM.VM.ObjectModel.{Get, ProxyTrap}

  def get(proxy_map, fallback) when is_function(fallback, 1) do
    target = Map.fetch!(proxy_map, proxy_target())
    handler = Map.fetch!(proxy_map, proxy_handler())

    cond do
      Map.get(proxy_map, "__proxy_revoked__") == true ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      not Value.object_like?(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      true ->
        get_trap(target, handler, fallback)
    end
  end

  defp get_trap(target, handler, fallback) do
    trap = Get.get(handler, "getPrototypeOf")

    if Value.nullish?(trap) do
      fallback.(target)
    else
      ProxyTrap.call(trap, [target], handler)
    end
  end
end
