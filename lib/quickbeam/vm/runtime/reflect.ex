defmodule QuickBEAM.VM.Runtime.Reflect do
  @moduledoc "JS `Reflect` built-in: `apply`, `construct`, `has`, `ownKeys`, `defineProperty`, and other reflection methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, JSThrow, Value}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Invocation

  alias QuickBEAM.VM.ObjectModel.{
    Delete,
    Get,
    HasProperty,
    OwnProperty,
    PropertyDescriptor,
    PropertyKey,
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

      if Value.nullish?(args_array) do
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
      reflect_get(obj, PropertyKey.to_property_key(key), receiver)
    end

    method "set" do
      [obj, key | rest] = args
      require_object!(obj, "Reflect.set")
      key = PropertyKey.to_property_key(key)
      val = arg(rest, 0, :undefined)
      receiver = arg(rest, 1, obj)
      Values.truthy?(Put.set(obj, key, val, receiver))
    end

    method "deleteProperty" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.deleteProperty")
      Delete.delete_property(obj, PropertyKey.to_property_key(key))
    end

    method "getOwnPropertyDescriptor" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.getOwnPropertyDescriptor")

      Object.static_property("getOwnPropertyDescriptor")
      |> Invocation.invoke_callback_or_throw([obj, PropertyKey.to_property_key(key)])
    end

    method "getPrototypeOf" do
      [obj | _] = args
      require_object!(obj, "Reflect.getPrototypeOf")
      Object.static_property("getPrototypeOf") |> Invocation.invoke_callback_or_throw([obj])
    end

    method "setPrototypeOf" do
      [obj, proto | _] = args
      reflect_set_prototype_of(obj, proto)
    end

    method "defineProperty" do
      obj = List.first(args, :undefined)
      key = Enum.at(args, 1, :undefined)
      descriptor = Enum.at(args, 2, :undefined)
      require_object!(obj, "Reflect.defineProperty")

      try do
        Object.static_property("defineProperty")
        |> Invocation.invoke_callback_or_throw([
          obj,
          PropertyKey.to_property_key(key),
          descriptor
        ])

        true
      catch
        {:js_throw, reason} ->
          if proxy_define_property_invariant_error?(reason) do
            throw({:js_throw, reason})
          else
            false
          end
      end
    end

    method "preventExtensions" do
      case hd(args) do
        {:obj, _} = obj -> prevent_extensions(obj)
        _ -> JSThrow.type_error!("Reflect.preventExtensions called on non-object")
      end
    end

    method "isExtensible" do
      obj = hd(args)
      require_object!(obj, "Reflect.isExtensible")
      extensible?(obj)
    end

    method "has" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.has")
      HasProperty.has_property?(obj, PropertyKey.to_property_key(key))
    end

    method "ownKeys" do
      obj = hd(args)
      require_object!(obj, "Reflect.ownKeys")
      Heap.wrap(own_keys_for(obj))
    end
  end

  defp proxy_define_property_invariant_error?(reason) do
    case Get.get(reason, "message") do
      message when is_binary(message) ->
        String.contains?(message, "proxy defineProperty trap violates invariant")

      _ ->
        false
    end
  end

  defp validate_constructable!(%QuickBEAM.VM.Function{}), do: :ok
  defp validate_constructable!({:closure, _, %QuickBEAM.VM.Function{}}), do: :ok
  defp validate_constructable!({:bound, _, _, _, _}), do: :ok

  defp validate_constructable!({:builtin, name, _} = builtin) do
    case QuickBEAM.VM.Builtin.metadata_for(builtin) do
      %QuickBEAM.VM.Builtin.Meta{constructable?: true} ->
        :ok

      nil ->
        if QuickBEAM.VM.Realm.intrinsic(builtin, :object) do
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

  defp reflect_get_object(obj, raw, key, receiver) when is_list(raw),
    do: reflect_get_array_object(obj, key, receiver)

  defp reflect_get_object(obj, {:qb_arr, _}, key, receiver),
    do: reflect_get_array_object(obj, key, receiver)

  defp reflect_get_object(obj, raw, key, receiver) do
    case Heap.raw_fetch(raw, key) do
      {:ok, value} -> reflect_get_value(value, receiver)
      :error -> reflect_get_from_prototype(Prototype.get(obj), key, receiver)
    end
  end

  defp reflect_get_array_object(obj, key, _receiver) do
    case PropertyKey.normalize(key) do
      "length" ->
        Get.length_of(obj)

      normalized_key ->
        Get.get(obj, normalized_key)
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
    unless proto == nil or Value.object_like?(proto) do
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
      obj == Heap.get_object_prototype() and proto != current ->
        false

      proto == obj ->
        false

      current == proto ->
        true

      not Heap.extensible?(ref) ->
        false

      Prototype.ordinary_chain_contains?(proto, ref) ->
        false

      true ->
        Prototype.set(obj, proto)
        true
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
    unless Value.object_like?(value) do
      JSThrow.type_error!("#{name} called on non-object")
    end
  end

  defp prevent_extensions({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "preventExtensions")

        cond do
          Value.nullish?(trap) ->
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

        if Value.nullish?(trap) do
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
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target, proxy_handler() => handler} ->
        own_keys_trap = Get.get(handler, "ownKeys")

        if Value.nullish?(own_keys_trap) do
          own_keys_for(target)
        else
          own_keys_trap
          |> Runtime.call_callback([target])
          |> Heap.to_list()
          |> OwnProperty.validate_proxy_own_keys_invariant(target)
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

  defp internal_key?(key), do: internal_slot?(key)
end
