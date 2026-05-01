defmodule QuickBEAM.VM.Runtime.Reflect do
  @moduledoc "JS `Reflect` built-in: `apply`, `construct`, `has`, `ownKeys`, `defineProperty`, and other reflection methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, JSThrow}
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
      try do
        Object.static_property("defineProperty") |> Invocation.invoke_callback_or_throw(args)
        true
      catch
        {:js_throw, _reason} -> false
      end
    end

    method "preventExtensions" do
      case hd(args) do
        {:obj, ref} ->
          Heap.prevent_extensions(ref)
          true

        _ ->
          false
      end
    end

    method "isExtensible" do
      case hd(args) do
        {:obj, ref} -> Heap.extensible?(ref)
        _ -> false
      end
    end

    method "has" do
      [obj, key | _] = args
      Put.has_property(obj, key)
    end

    method "ownKeys" do
      case hd(args) do
        {:obj, _} = obj -> Heap.wrap(own_keys_for(obj))
        _ -> Heap.wrap([])
      end
    end
  end

  defp own_keys_for({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        own_keys_trap = Get.get(handler, "ownKeys")

        if own_keys_trap == :undefined or own_keys_trap == nil do
          own_keys_for(target)
        else
          trap_keys =
            own_keys_trap
            |> Runtime.call_callback([target])
            |> Heap.to_list()

          validate_proxy_own_keys_invariant(target, trap_keys)
        end

      map ->
        own_keys(map)
    end
  end

  defp validate_proxy_own_keys_invariant(target, trap_keys) do
    target_keys = own_keys_for(target)

    missing_key =
      Enum.find(target_keys, fn key ->
        match?(%{configurable: false}, target_prop_desc(target, key)) and key not in trap_keys
      end)

    cond do
      duplicate_key?(trap_keys) ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      missing_key ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      non_extensible_key_mismatch?(target, target_keys, trap_keys) ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      true ->
        trap_keys
    end
  end

  defp duplicate_key?(keys) do
    Enum.uniq(keys) != keys
  end

  defp non_extensible_key_mismatch?({:obj, ref}, target_keys, trap_keys) do
    not Heap.extensible?(ref) and Enum.sort(target_keys) != Enum.sort(trap_keys)
  end

  defp non_extensible_key_mismatch?(_, _, _), do: false

  defp target_prop_desc({:obj, ref}, key), do: Heap.get_prop_desc(ref, key)
  defp target_prop_desc(_, _), do: nil

  defp own_keys(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.reject(&internal_key?/1)
    |> Enum.map(&normalize_key/1)
  end

  defp own_keys(_), do: []

  defp internal_key?(key)
       when key in [key_order(), proto(), map_data(), proxy_target(), proxy_handler(), set_data()],
       do: true

  defp internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp internal_key?(_), do: false

  defp normalize_key(key) when is_integer(key) and key >= 0, do: Integer.to_string(key)
  defp normalize_key(key), do: key
end
