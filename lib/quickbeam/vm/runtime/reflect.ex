defmodule QuickBEAM.VM.Runtime.Reflect do
  @moduledoc "JS `Reflect` built-in: `apply`, `construct`, `has`, `ownKeys`, `defineProperty`, and other reflection methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, JSThrow, Value}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Invocation

  alias QuickBEAM.VM.ObjectModel.{
    Get,
    InternalMethods,
    PropertyDescriptor,
    PropertyKey,
    Prototype
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

      Invocation.invoke_with_receiver(target, call_args, Runtime.gas_budget(), this_arg)
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
      Values.truthy?(InternalMethods.set(obj, key, val, receiver))
    end

    method "deleteProperty" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.deleteProperty")
      InternalMethods.delete(obj, PropertyKey.to_property_key(key))
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
        {:js_throw, _reason} -> false
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
      InternalMethods.extensible?(obj)
    end

    method "has" do
      [obj, key | _] = args
      require_object!(obj, "Reflect.has")
      InternalMethods.has_property(obj, PropertyKey.to_property_key(key))
    end

    method "ownKeys" do
      obj = hd(args)
      require_object!(obj, "Reflect.ownKeys")
      Heap.wrap(InternalMethods.own_keys(obj))
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

  defp reflect_get(obj, key, receiver), do: InternalMethods.get(obj, key, receiver)

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
    current = InternalMethods.get_prototype_of(obj)

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
        InternalMethods.set_prototype_of(obj, proto)
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

          InternalMethods.extensible?(target) ->
            JSThrow.type_error!("proxy preventExtensions trap violates invariant")

          true ->
            true
        end

      _ ->
        Heap.prevent_extensions(ref)
        true
    end
  end
end
