defmodule QuickBEAM.VM.Runtime.Reflect do
  @moduledoc "JS `Reflect` built-in: `apply`, `construct`, `has`, `ownKeys`, `defineProperty`, and other reflection methods."

  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Delete, Get, Put}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Object

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
      [target, args_array | rest] = args
      call_args = Heap.to_list(args_array)
      new_target = arg(rest, 0, target)
      Invocation.construct_runtime(target, new_target, call_args)
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

    method "deleteProperty" do
      [obj, key | _] = args
      Delete.delete_property(obj, key)
    end

    method "defineProperty" do
      Object.static_property("defineProperty") |> Runtime.call_callback(args)
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
