defmodule QuickBEAM.VM.Runtime.ObjectDescriptors do
  @moduledoc "Descriptor operations for Object.defineProperty and related statics."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Execution.RegexpState

  alias QuickBEAM.VM.ObjectModel.{
    Get,
    InternalMethods,
    OwnProperty,
    PropertyDescriptor,
    PropertyKey
  }

  alias QuickBEAM.VM.Runtime.ObjectEnumeration
  alias QuickBEAM.VM.Semantics.Values

  def own_property_descriptors([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def own_property_descriptors([obj | _]) do
    ref = make_ref()
    keys = OwnProperty.descriptor_keys(obj)

    descriptors =
      Enum.reduce(keys, %{key_order() => descriptor_result_key_order(keys)}, fn key, acc ->
        case own_property_descriptor([obj, key]) do
          :undefined -> acc
          desc -> Map.put(acc, key, desc)
        end
      end)

    Heap.put_obj(ref, descriptors)
    {:obj, ref}
  end

  def own_property_descriptors(_), do: Heap.wrap(%{})

  def define_property([{:obj, _} = obj, key, {:obj, desc_ref} = desc_obj | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    InternalMethods.define_own_property(obj, key, desc_obj, desc)
  end

  def define_property([{:regexp, _, _, ref} = regexp, key, {:obj, desc_ref} = desc_obj | _]) do
    key = PropertyKey.normalize(key)
    desc = Heap.get_obj(desc_ref, %{})
    existing_flags = Heap.get_prop_desc(ref, key)

    if match?(%{configurable: false}, existing_flags) and Map.get(desc, "configurable") == true do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    value =
      if getter != nil or setter != nil,
        do: {:accessor, getter, setter},
        else: Map.get(desc, "value", Get.get(regexp, key))

    attrs =
      PropertyDescriptor.attrs(
        writable: PropertyDescriptor.attribute(desc_obj, desc, "writable", existing_flags, false),
        enumerable:
          PropertyDescriptor.attribute(desc_obj, desc, "enumerable", existing_flags, false),
        configurable:
          PropertyDescriptor.attribute(desc_obj, desc, "configurable", existing_flags, false)
      )

    RegexpState.put(ref, key, value)
    Heap.put_prop_desc(ref, key, attrs)
    regexp
  end

  def define_property([{:obj, _} = obj, key, desc | _]) when is_map(desc) do
    InternalMethods.define_own_property(obj, key, Heap.wrap(desc), desc)
  end

  def define_property([{:obj, _} = obj, key, desc_obj | _])
      when is_tuple(desc_obj) or is_struct(desc_obj) do
    if descriptor_object?(desc_obj) do
      InternalMethods.define_own_property(obj, key, desc_obj, %{})
    else
      throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
    end
  end

  def define_property([{:closure, _, %QuickBEAM.VM.Function{}} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  def define_property([{:bound, _, _, _, _} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  def define_property([%QuickBEAM.VM.Function{} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  def define_property([{:builtin, _, _} = builtin, key, {:obj, desc_ref} | _]) do
    define_static_property(builtin, key, desc_ref)
    builtin
  end

  def define_property(_args) do
    throw({:js_throw, Heap.make_error("Object.defineProperty called on non-object", "TypeError")})
  end

  def define_properties([target, _props | _]) when is_nullish(target) do
    throw(
      {:js_throw, Heap.make_error("Object.defineProperties called on non-object", "TypeError")}
    )
  end

  def define_properties([target, _props | _])
      when not is_tuple(target) and not is_struct(target) do
    throw(
      {:js_throw, Heap.make_error("Object.defineProperties called on non-object", "TypeError")}
    )
  end

  def define_properties([obj, {:obj, props_ref} = props | _]) do
    for key <- define_properties_keys(props, props_ref) do
      define_property([obj, key, Get.get(props, key)])
    end

    obj
  end

  def define_properties([obj, props | _]) when is_tuple(props) or is_struct(props) do
    if descriptor_object?(props) do
      for key <- callable_own_keys(props) do
        define_property([obj, key, Get.get(props, key)])
      end

      obj
    else
      obj
    end
  end

  def define_properties([_obj, props | _]) when is_nullish(props) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def define_properties([obj, props | _]) when is_binary(props) do
    if props == "" do
      obj
    else
      throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
    end
  end

  def define_properties([obj | _]), do: obj

  def own_property_descriptor([target, _key | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def own_property_descriptor([target, key | _]), do: InternalMethods.own_property(target, key)
  def own_property_descriptor([target]), do: InternalMethods.own_property(target, :undefined)
  def own_property_descriptor(_), do: :undefined

  defp descriptor_result_key_order(keys) do
    if Enum.all?(keys, &QuickBEAM.VM.Value.is_symbol/1), do: keys, else: Enum.reverse(keys)
  end

  defp descriptor_object?(value), do: Value.object_like?(value)

  defp define_callable_property(fun, key, desc_ref) do
    define_static_property(fun, key, desc_ref)
    fun
  end

  defp callable_own_keys({:regexp, _, _, ref}) do
    ref
    |> RegexpState.get()
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 in ["flags", "source", "lastIndex"]))
    |> Enum.reject(fn key -> internal?(key) end)
  end

  defp callable_own_keys(callable) do
    callable
    |> Heap.get_ctor_statics()
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(fn key -> internal?(key) end)
  end

  defp define_static_property(target, key, desc_ref) do
    desc_obj = {:obj, desc_ref}
    desc = Heap.get_obj(desc_ref, %{})
    prop_key = if is_binary(key), do: key, else: key

    reject_incompatible_static_descriptor!(target, prop_key, desc)

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    if getter != nil or setter != nil do
      Heap.put_ctor_static(target, prop_key, {:accessor, getter, setter})
    else
      val = Map.get(desc, "value", Get.get(target, prop_key))
      Heap.put_ctor_static(target, prop_key, val)
    end

    existing_flags =
      Heap.get_prop_desc(target, prop_key) || Heap.get_ctor_prop_desc(target, prop_key)

    attrs =
      PropertyDescriptor.attrs(
        writable: PropertyDescriptor.attribute(desc_obj, desc, "writable", existing_flags, false),
        enumerable:
          PropertyDescriptor.attribute(desc_obj, desc, "enumerable", existing_flags, false),
        configurable:
          PropertyDescriptor.attribute(desc_obj, desc, "configurable", existing_flags, false)
      )

    Heap.put_prop_desc(target, prop_key, attrs)
    Heap.put_ctor_prop_desc(target, prop_key, attrs)
  end

  defp reject_incompatible_static_descriptor!(target, prop_key, desc) do
    case Heap.get_prop_desc(target, prop_key) || Heap.get_ctor_prop_desc(target, prop_key) do
      %{configurable: false} = current ->
        cond do
          Map.get(desc, "configurable") == true ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          Map.has_key?(desc, "enumerable") and Map.get(desc, "enumerable") != current.enumerable ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          current.writable == false and Map.get(desc, "writable") == true ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp define_properties_keys(props, props_ref) do
    case Heap.get_obj(props_ref, %{}) do
      map when is_map(map) and is_map_key(map, proxy_target()) ->
        props
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(fn key ->
          case InternalMethods.own_property(props, key) do
            {:obj, _} = desc -> Values.truthy?(Get.get(desc, "enumerable"))
            _ -> false
          end
        end)

      _ ->
        ObjectEnumeration.enumerable_keys(props_ref)
    end
  end
end
