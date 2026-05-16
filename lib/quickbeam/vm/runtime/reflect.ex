defmodule QuickBEAM.VM.Runtime.Reflect do
  @moduledoc "JS `Reflect` built-in: `apply`, `construct`, `has`, `ownKeys`, `defineProperty`, and other reflection methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation

  alias QuickBEAM.VM.ObjectModel.{
    Delete,
    Get,
    HasProperty,
    OwnProperty,
    PropertyDescriptor,
    Prototype,
    Put
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Object

  @method_lengths %{
    "apply" => 3,
    "construct" => 2,
    "defineProperty" => 3,
    "deleteProperty" => 2,
    "get" => 2,
    "getOwnPropertyDescriptor" => 2,
    "getPrototypeOf" => 1,
    "has" => 2,
    "isExtensible" => 1,
    "ownKeys" => 1,
    "preventExtensions" => 1,
    "set" => 3,
    "setPrototypeOf" => 2
  }

  def install_metadata({:builtin, _name, map} = reflect) when is_map(map) do
    Enum.each(@method_lengths, fn {name, length} ->
      method = Map.get(map, name)
      Heap.put_ctor_static(reflect, name, method)
      Heap.put_prop_desc(reflect, name, PropertyDescriptor.method())
      Heap.put_ctor_prop_desc(reflect, name, PropertyDescriptor.method())

      case method do
        {:builtin, _, _} = method ->
          Heap.put_ctor_static(method, "length", length)

          Heap.put_ctor_prop_desc(method, "length", PropertyDescriptor.hidden_readonly())

        _ ->
          :ok
      end
    end)

    tag = {:symbol, "Symbol.toStringTag"}
    Heap.put_ctor_static(reflect, tag, "Reflect")
    Heap.put_prop_desc(reflect, tag, PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(reflect, tag, PropertyDescriptor.hidden_readonly())

    case Heap.get_object_prototype() do
      {:obj, _} = object_proto -> Heap.put_ctor_static(reflect, proto(), object_proto)
      _ -> :ok
    end

    reflect
  end

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

      call_args = create_list_from_array_like(args_array)

      Interpreter.invoke_with_receiver(
        target,
        call_args,
        Runtime.gas_budget(),
        this_arg
      )
    end

    method "construct" do
      [target, args_array | rest] = args
      call_args = create_list_from_array_like(args_array)
      new_target = arg(rest, 0, target)
      validate_constructable!(new_target)
      Invocation.construct_runtime(target, new_target, call_args)
    end

    method "get" do
      [obj, key | rest] = args
      require_object!(obj, "Reflect.get")
      receiver = arg(rest, 0, obj)
      reflect_get(obj, key, receiver)
    end

    method "set" do
      [obj, key | rest] = args
      require_object!(obj, "Reflect.set")
      val = arg(rest, 0, :undefined)
      receiver = arg(rest, 1, obj)
      Values.truthy?(Put.set(obj, key, val, receiver))
    end

    method "deleteProperty" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.deleteProperty")
      Delete.delete_property(obj, key)
    end

    method "getOwnPropertyDescriptor" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.getOwnPropertyDescriptor")

      Object.static_property("getOwnPropertyDescriptor")
      |> Invocation.invoke_callback_or_throw([obj, key])
    end

    method "getPrototypeOf" do
      [obj | _] = args

      case obj do
        {:obj, _} ->
          Object.static_property("getPrototypeOf") |> Invocation.invoke_callback_or_throw([obj])

        _ ->
          JSThrow.type_error!("Reflect.getPrototypeOf called on non-object")
      end
    end

    method "setPrototypeOf" do
      [obj, proto | _] = args
      reflect_set_prototype_of(obj, proto)
    end

    method "defineProperty" do
      case hd(args) do
        {:obj, _} ->
          try do
            Object.static_property("defineProperty") |> Invocation.invoke_callback_or_throw(args)
            true
          catch
            {:js_throw, _reason} -> false
          end

        _ ->
          JSThrow.type_error!("Reflect.defineProperty called on non-object")
      end
    end

    method "preventExtensions" do
      case hd(args) do
        {:obj, _} = obj -> prevent_extensions(obj)
        _ -> JSThrow.type_error!("Reflect.preventExtensions called on non-object")
      end
    end

    method "isExtensible" do
      case hd(args) do
        {:obj, _} = obj -> extensible?(obj)
        _ -> JSThrow.type_error!("Reflect.isExtensible called on non-object")
      end
    end

    method "has" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.has")
      HasProperty.has_property?(obj, key)
    end

    method "ownKeys" do
      obj = hd(args)
      require_object!(obj, "Reflect.ownKeys")
      Heap.wrap(own_keys_for(obj))
    end
  end

  defp validate_constructable!(%QuickBEAM.VM.Function{}), do: :ok
  defp validate_constructable!({:closure, _, %QuickBEAM.VM.Function{}}), do: :ok
  defp validate_constructable!({:bound, _, _, _, _}), do: :ok

  defp validate_constructable!({:builtin, name, _} = builtin) do
    case QuickBEAM.VM.Builtin.named_meta(name) do
      %QuickBEAM.VM.Builtin.Meta{constructable?: true} ->
        :ok

      nil ->
        if QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(builtin, :object) do
          :ok
        else
          JSThrow.type_error!("#{name} is not a constructor")
        end

      _ ->
        JSThrow.type_error!("#{name} is not a constructor")
    end
  end

  defp validate_constructable!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target} -> validate_constructable!(target)
      _ -> JSThrow.type_error!("newTarget is not a constructor")
    end
  end

  defp validate_constructable!(_), do: JSThrow.type_error!("newTarget is not a constructor")

  defp reflect_get(obj, key, receiver) do
    case obj do
      {:obj, ref} -> reflect_get_object(obj, Heap.get_obj_raw(ref), key, receiver)
      _ -> Get.get(obj, key)
    end
  end

  defp reflect_get_object(obj, raw, key, receiver) do
    case raw do
      {:shape, _shape_id, offsets, vals, _proto} ->
        case Map.fetch(offsets, key) do
          {:ok, offset} -> reflect_get_value(elem(vals, offset), receiver)
          :error -> reflect_get_from_prototype(Prototype.get(obj), key, receiver)
        end

      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, value} -> reflect_get_value(value, receiver)
          :error -> reflect_get_from_prototype(Prototype.get(obj), key, receiver)
        end

      _ ->
        Get.get(obj, key)
    end
  end

  defp reflect_get_value({:accessor, getter, _}, receiver) when getter != nil,
    do: Get.call_getter(getter, receiver)

  defp reflect_get_value({:accessor, nil, _}, _receiver), do: :undefined
  defp reflect_get_value(value, _receiver), do: value

  defp reflect_get_from_prototype(nil, _key, _receiver), do: :undefined
  defp reflect_get_from_prototype(:undefined, _key, _receiver), do: :undefined
  defp reflect_get_from_prototype(proto, key, receiver), do: reflect_get(proto, key, receiver)

  defp reflect_set_prototype_of({:obj, ref} = obj, proto) do
    unless proto == nil or object?(proto) do
      JSThrow.type_error!("Reflect.setPrototypeOf prototype must be an object or null")
    end

    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, proxy_handler() => _handler} ->
        try do
          Object.static_property("setPrototypeOf")
          |> Invocation.invoke_callback_or_throw([obj, proto])

          true
        catch
          {:js_throw, _reason} -> false
        end

      _ ->
        reflect_set_ordinary_prototype(obj, ref, proto)
    end
  end

  defp reflect_set_prototype_of(_obj, _proto),
    do: JSThrow.type_error!("Reflect.setPrototypeOf called on non-object")

  defp reflect_set_ordinary_prototype(obj, ref, proto) do
    current = Prototype.get(obj)

    cond do
      proto == obj ->
        false

      current == proto ->
        true

      not Heap.extensible?(ref) ->
        false

      prototype_chain_contains?(proto, ref) ->
        false

      true ->
        Prototype.set(obj, proto)
        true
    end
  end

  defp prototype_chain_contains?(proto, ref) do
    case proto do
      {:obj, proto_ref} when proto_ref == ref -> true
      {:obj, _} -> prototype_chain_contains?(Prototype.get(proto), ref)
      _ -> false
    end
  end

  defp create_list_from_array_like(value) do
    require_object!(value, "CreateListFromArrayLike")

    length = value |> Get.get("length") |> Runtime.to_number()
    length = if is_number(length) and length > 0, do: trunc(length), else: 0

    for index <- 0..(length - 1)//1 do
      Get.get(value, Integer.to_string(index))
    end
  end

  defp require_object!(value, name) do
    unless object?(value) do
      JSThrow.type_error!("#{name} called on non-object")
    end
  end

  defp object?({:obj, _}), do: true
  defp object?(%QuickBEAM.VM.Function{}), do: true
  defp object?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp object?({:bound, _, _, _, _}), do: true
  defp object?({:builtin, _, _}), do: true
  defp object?(_), do: false

  defp prevent_extensions({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "preventExtensions")

        cond do
          trap == :undefined or trap == nil ->
            prevent_extensions(target)

          not Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target])) ->
            false

          extensible?(target) ->
            JSThrow.type_error!("proxy preventExtensions trap violates invariant")

          true ->
            true
        end

      _ ->
        Heap.prevent_extensions(ref)
        true
    end
  end

  defp extensible?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "isExtensible")

        if trap == :undefined or trap == nil do
          extensible?(target)
        else
          trap_result = Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target]))
          target_result = extensible?(target)

          if trap_result == target_result do
            trap_result
          else
            JSThrow.type_error!("proxy isExtensible trap violates invariant")
          end
        end

      _ ->
        Heap.extensible?(ref)
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

      {:qb_arr, arr} ->
        sparse_array_keys(ref, :array.to_list(arr))

      list when is_list(list) ->
        sparse_array_keys(ref, list)

      map when is_map(map) ->
        OwnProperty.own_keys({:obj, ref})

      _ ->
        OwnProperty.own_keys({:obj, ref})
    end
  end

  defp own_keys_for(target) when is_tuple(target) or is_struct(target) do
    OwnProperty.own_keys(target)
  end

  defp sparse_array_keys(ref, list) do
    indexed_keys =
      list
      |> Enum.with_index()
      |> Enum.reject(fn {value, _index} -> value == :undefined end)
      |> Enum.map(fn {_value, index} -> Integer.to_string(index) end)

    side_keys =
      ref
      |> Heap.get_array_props()
      |> Map.keys()
      |> Enum.reject(&(&1 == "length" or internal_key?(&1)))

    indexed_keys ++ side_keys ++ ["length"]
  end

  defp internal_key?(key)
       when key in [key_order(), proto(), map_data(), proxy_target(), proxy_handler(), set_data()],
       do: true

  defp internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp internal_key?(_), do: false

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

  defp target_prop_desc({:obj, ref}, key), do: Heap.get_prop_desc(ref, key)
end
