defmodule QuickBEAM.VM.Runtime.Proxy do
  @moduledoc "Installs the Proxy constructor and Proxy.revocable helper."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.ConstructorCallbacks

  use QuickBEAM.VM.Builtin

  builtin_definition("Proxy",
    constructor: &ConstructorCallbacks.proxy/2,
    length: 2,
    phase: :fundamental,
    module: __MODULE__,
    after_install: &__MODULE__.install_builtin/1
  )

  def install_builtin(ctor) do
    revocable = {:builtin, "revocable", &revocable/2}
    Heap.put_ctor_static(ctor, "revocable", revocable)
    Heap.put_ctor_static(revocable, "length", 2)
    Heap.put_ctor_static(revocable, "name", "revocable")

    Heap.put_ctor_prop_desc(revocable, "length", %{
      writable: false,
      enumerable: false,
      configurable: true
    })

    Heap.put_ctor_prop_desc(revocable, "name", %{
      writable: false,
      enumerable: false,
      configurable: true
    })
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
