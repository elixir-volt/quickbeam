defmodule QuickBEAM.BeamVM.Runtime.Reflect do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime.Property
  alias QuickBEAM.BeamVM.Interpreter.Objects

  js_object "Reflect" do
    method "get" do
      [obj, key | _] = args
      Property.get(obj, key)
    end

    method "set" do
      [obj, key, val | _] = args
      Objects.put(obj, key, val)
      true
    end

    method "has" do
      [obj, key | _] = args
      Objects.has_property(obj, key)
    end

    method "ownKeys" do
      case hd(args) do
        {:obj, ref} -> Heap.wrap(Map.keys(Heap.get_obj(ref, %{})))
        _ -> Heap.wrap([])
      end
    end
  end
end
