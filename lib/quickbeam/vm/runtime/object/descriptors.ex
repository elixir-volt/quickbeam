defmodule QuickBEAM.VM.Runtime.Object.Descriptors do
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
    PropertyKey,
    Semantics
  }

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

  def own_property_descriptors(_) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

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

  def define_property([{:closure, _, %QuickBEAM.VM.Function{}} = fun, key, desc | _]) do
    define_callable_property(fun, key, desc)
  end

  def define_property([{:bound, _, _, _, _} = fun, key, desc | _]) do
    define_callable_property(fun, key, desc)
  end

  def define_property([%QuickBEAM.VM.Function{} = fun, key, desc | _]) do
    define_callable_property(fun, key, desc)
  end

  def define_property([{:builtin, _, _} = builtin, key, desc | _]) do
    define_callable_property(builtin, key, desc)
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
    descriptors =
      props
      |> define_properties_keys(props_ref)
      |> Enum.map(fn key -> {key, property_descriptor_arg!(Get.get(props, key))} end)

    Enum.each(descriptors, fn {key, desc} -> define_property([obj, key, desc]) end)
    obj
  end

  def define_properties([obj, props | _]) when is_tuple(props) or is_struct(props) do
    if descriptor_object?(props) do
      descriptors =
        props
        |> define_properties_keys(nil)
        |> Enum.map(fn key -> {key, property_descriptor_arg!(Get.get(props, key))} end)

      Enum.each(descriptors, fn {key, desc} -> define_property([obj, key, desc]) end)
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

  def own_property_descriptor(_) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp descriptor_result_key_order(keys), do: Enum.reverse(keys)

  defp descriptor_object?(value), do: Value.object_like?(value)

  defp define_callable_property(fun, key, {:obj, desc_ref}) do
    define_static_property(fun, key, desc_ref)
    fun
  end

  defp define_callable_property(fun, key, desc) when is_map(desc) do
    desc_ref = elem(Heap.wrap(desc), 1)
    define_static_property(fun, key, desc_ref)
    fun
  end

  defp define_callable_property(fun, key, desc_obj)
       when is_tuple(desc_obj) or is_struct(desc_obj) do
    if descriptor_object?(desc_obj) do
      InternalMethods.define_own_property(fun, key, desc_obj, %{})
    else
      throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
    end
  end

  defp define_static_property(target, key, desc_ref) do
    desc_obj = {:obj, desc_ref}
    desc = Heap.get_obj(desc_ref, %{})
    prop_key = PropertyKey.normalize(key)

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
    current_value = Get.get(target, prop_key)

    case Heap.get_prop_desc(target, prop_key) || Heap.get_ctor_prop_desc(target, prop_key) do
      %{configurable: false} = current ->
        cond do
          Map.get(desc, "configurable") == true ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          Map.has_key?(desc, "enumerable") and Map.get(desc, "enumerable") != current.enumerable ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          current.writable == false and Map.get(desc, "writable") == true ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          current.writable == false and Map.has_key?(desc, "value") and
              not Semantics.same_value?(Map.get(desc, "value"), current_value) ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp property_descriptor_arg!({:obj, _} = desc), do: desc
  defp property_descriptor_arg!(desc) when is_map(desc), do: Heap.wrap(desc)

  defp property_descriptor_arg!(desc) when is_tuple(desc) or is_struct(desc) do
    if descriptor_object?(desc) do
      desc
    else
      throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
    end
  end

  defp property_descriptor_arg!(_) do
    throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
  end

  defp define_properties_keys(props, _props_ref) do
    props
    |> InternalMethods.own_keys()
    |> Enum.filter(fn key ->
      case InternalMethods.own_property(props, key) do
        {:obj, _} = desc -> Values.truthy?(Get.get(desc, "enumerable"))
        _ -> false
      end
    end)
  end
end
