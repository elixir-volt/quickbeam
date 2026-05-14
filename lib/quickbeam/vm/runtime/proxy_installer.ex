defmodule QuickBEAM.VM.Runtime.ProxyInstaller do
  @moduledoc "Installs the Proxy constructor and Proxy.revocable helper."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors

  @doc "Returns the global Proxy constructor binding."
  def constructor do
    ctor = ConstructorRegistry.register("Proxy", &Constructors.proxy/2)

    Heap.put_ctor_static(
      ctor,
      "revocable",
      {:builtin, "revocable", &revocable/2}
    )

    ctor
  end

  defp revocable([target, handler | _], _this) do
    proxy = Constructors.proxy([target, handler], nil)

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
