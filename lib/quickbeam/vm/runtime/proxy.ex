defmodule QuickBEAM.VM.Runtime.Proxy do
  @moduledoc "Installs the Proxy constructor and Proxy.revocable helper."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.ConstructorCallbacks

  use QuickBEAM.VM.Builtin

  defintrinsic "Proxy" do
    constructor(&ConstructorCallbacks.proxy/2,
      length: 2,
      phase: :fundamental
    )
  end

  @ecma "28.2.2.1"
  static "revocable", length: 2 do
    revocable(args, this)
  end

  defp revocable([target, handler | _], _this) do
    proxy = ConstructorCallbacks.proxy([target, handler], nil)

    revoke_fn =
      {:builtin, "revoke",
       fn _, _ ->
         {:obj, proxy_ref} = proxy
         Heap.put_obj_key(proxy_ref, "__proxy_revoked__", true)
         :undefined
       end}

    Heap.wrap(%{"proxy" => proxy, "revoke" => revoke_fn})
  end
end
