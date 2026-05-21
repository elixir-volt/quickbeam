defmodule QuickBEAM.VM.Host.Test262 do
  @moduledoc "Minimal Test262 host hooks used by compatibility tests."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Realm
  import QuickBEAM.VM.Heap.Keys, only: [buffer: 0]

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  @impl true
  def bindings, do: %{"$262" => object()}

  def object do
    Heap.wrap(%{
      "createRealm" => {:builtin, "createRealm", fn _, _ -> Realm.create() end},
      "detachArrayBuffer" =>
        {:builtin, "detachArrayBuffer", fn args, _ -> detach_array_buffer(args) end}
    })
  end

  defp detach_array_buffer([{:obj, ref} | _]) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        Heap.put_obj(
          ref,
          Map.merge(map, %{buffer() => <<>>, "byteLength" => 0, "__detached__" => true})
        )

      _ ->
        :ok
    end

    :undefined
  end

  defp detach_array_buffer(_), do: :undefined
end
