defmodule QuickBEAM.VM.ObjectModel.ProxyDispatch do
  @moduledoc "Shared Proxy target, handler, and trap lookup helpers."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{JSThrow, Value}
  alias QuickBEAM.VM.ObjectModel.Get

  def target_handler!(proxy_map) when is_map(proxy_map) do
    cond do
      Map.get(proxy_map, "__proxy_revoked__") == true ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      true ->
        target = Map.fetch!(proxy_map, proxy_target())
        handler = Map.fetch!(proxy_map, proxy_handler())

        if Value.object_like?(handler) do
          {target, handler}
        else
          JSThrow.type_error!("Cannot perform operation on a proxy with null handler")
        end
    end
  end

  def trap(handler, name), do: Get.get(handler, name)

  def with_trap(proxy_map, name, fallback, fun)
      when is_function(fallback, 1) and is_function(fun, 3) do
    {target, handler} = target_handler!(proxy_map)

    case callable_trap!(trap(handler, name), name) do
      nil -> fallback.(target)
      trap -> fun.(target, handler, trap)
    end
  end

  def callable_trap!(trap, name) do
    cond do
      Value.nullish?(trap) ->
        nil

      QuickBEAM.VM.Builtin.callable?(trap) ->
        trap

      true ->
        JSThrow.type_error!("proxy #{name} trap is not callable")
    end
  end
end
