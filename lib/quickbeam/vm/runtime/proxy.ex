defmodule QuickBEAM.VM.Runtime.Proxy do
  @moduledoc "Installs the Proxy constructor and Proxy.revocable helper."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Globals.Constructors

  use QuickBEAM.VM.Builtin

  builtin_definition("Proxy",
    constructor: &Constructors.proxy/2,
    length: 2,
    phase: :fundamental,
    module: __MODULE__,
    after_install: &__MODULE__.install_builtin/1
  )

  def install_builtin(ctor) do
    Heap.put_ctor_static(ctor, "revocable", {:builtin, "revocable", &revocable/2})
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
