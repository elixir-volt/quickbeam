defmodule QuickBEAM.BeamVM.Runtime.Reflect do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.ObjectModel.{Get, Put}
  alias QuickBEAM.BeamVM.Runtime

  js_object "Reflect" do
    method "apply" do
      [target, this_arg | rest] = args
      args_array = List.first(rest)

      if args_array == :undefined or args_array == nil do
        throw(
          {:js_throw,
           Heap.make_error("CreateListFromArrayLike called on non-object", "TypeError")}
        )
      end

      call_args = Heap.to_list(args_array)

      Interpreter.invoke_with_receiver(
        target,
        call_args,
        Runtime.gas_budget(),
        this_arg
      )
    end

    method "construct" do
      [target, args_array | _] = args
      call_args = Heap.to_list(args_array)
      Runtime.call_callback(target, call_args)
    end

    method "get" do
      [obj, key | _] = args
      Get.get(obj, key)
    end

    method "set" do
      [obj, key, val | _] = args
      Put.put(obj, key, val)
      true
    end

    method "has" do
      [obj, key | _] = args
      Put.has_property(obj, key)
    end

    method "ownKeys" do
      case hd(args) do
        {:obj, ref} -> Heap.wrap(Map.keys(Heap.get_obj(ref, %{})))
        _ -> Heap.wrap([])
      end
    end
  end
end
