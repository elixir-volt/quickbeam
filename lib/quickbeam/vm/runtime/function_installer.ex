defmodule QuickBEAM.VM.Runtime.FunctionInstaller do
  @moduledoc "Installs the Function constructor and prototype metadata."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{PropertyDescriptor, Put}
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Function
  alias QuickBEAM.VM.Runtime.Globals.Constructors

  @doc "Returns the global Function constructor binding."
  def constructor do
    fun_ctor =
      ConstructorRegistry.register("Function", &Constructors.function/2,
        prototype: Function.prototype()
      )

    case Heap.get_ctor_statics(fun_ctor)["prototype"] do
      {:obj, _} = proto -> Put.put(proto, "constructor", fun_ctor)
      _ -> :ok
    end

    Heap.put_prop_desc(fun_ctor, "prototype", PropertyDescriptor.prototype())
    fun_ctor
  end
end
