defmodule QuickBEAM.BeamVM.Runtime.Reflect do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap

  js_object "Reflect" do
    method "get" do
      [obj, key | _] = args
      QuickBEAM.BeamVM.Runtime.get_property(obj, key)
    end

    method "set" do
      [obj, key, val | _] = args
      QuickBEAM.BeamVM.Interpreter.Objects.put(obj, key, val)
      true
    end

    method "has" do
      [obj, key | _] = args
      QuickBEAM.BeamVM.Interpreter.Objects.has_property(obj, key)
    end

    method "ownKeys" do
      case hd(args) do
        {:obj, ref} -> Heap.wrap(Map.keys(Heap.get_obj(ref, %{})))
        _ -> Heap.wrap([])
      end
    end
  end
end
