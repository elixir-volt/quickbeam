defmodule QuickBEAM.VM.Runtime.Object.Integrity do
  @moduledoc "Object integrity operations for Object.freeze/seal/preventExtensions checks."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_handler: 0, proxy_target: 0, typed_array: 0]

  alias QuickBEAM.VM.{Heap, Invocation, JSThrow, Value}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, OwnProperty}
  alias QuickBEAM.VM.Semantics.Values

  def freeze({:obj, _ref} = obj) do
    freeze_object(obj)
    obj
  end

  def freeze({:regexp, _, _, ref} = regexp) do
    freeze_regexp(regexp, ref)
    regexp
  end

  def freeze(callable) when is_tuple(callable) or is_struct(callable) do
    freeze_callable(callable)
    callable
  end

  def freeze(value), do: value

  def prevent_extensions({:obj, _} = obj) do
    if prevent_extensions_object(obj) do
      obj
    else
      throw({:js_throw, Heap.make_error("Cannot prevent extensions", "TypeError")})
    end
  end

  def prevent_extensions(value) do
    if object_like?(value), do: Heap.prevent_extensions(value)
    value
  end

  def extensible?({:builtin, "ThrowTypeError", _}), do: false

  def extensible?(value),
    do: if(object_like?(value), do: InternalMethods.extensible?(value), else: false)

  def seal({:obj, _ref} = obj) do
    seal_object(obj)
    obj
  end

  def seal({:regexp, _, _, ref} = regexp) do
    seal_regexp(regexp, ref)
    regexp
  end

  def seal(callable) when is_tuple(callable) or is_struct(callable) do
    if object_like?(callable), do: seal_callable(callable)
    callable
  end

  def seal(value), do: value

  def frozen?({:obj, _ref} = obj), do: frozen_object?(obj)
  def frozen?(value), do: if(object_like?(value), do: frozen_object_like?(value), else: true)

  def sealed?({:obj, _ref} = obj), do: sealed_object?(obj)
  def sealed?(value), do: if(object_like?(value), do: sealed_object_like?(value), else: true)

  defp freeze_callable(callable) do
    for key <- OwnProperty.descriptor_keys(callable) do
      case InternalMethods.own_property(callable, key) do
        :undefined ->
          :ok

        desc ->
          current = callable_descriptor_attrs(callable, key)

          attrs =
            if Get.get(desc, "writable") == :undefined do
              Map.put(current, :configurable, false)
            else
              %{current | writable: false, configurable: false}
            end

          Heap.put_ctor_prop_desc(callable, key, attrs)
          Heap.put_prop_desc(callable, key, attrs)
      end
    end

    Heap.prevent_extensions(callable)
  end

  defp seal_callable(callable) do
    for key <- OwnProperty.descriptor_keys(callable) do
      unless InternalMethods.own_property(callable, key) == :undefined do
        attrs = callable |> callable_descriptor_attrs(key) |> Map.put(:configurable, false)
        Heap.put_ctor_prop_desc(callable, key, attrs)
        Heap.put_prop_desc(callable, key, attrs)
      end
    end

    Heap.prevent_extensions(callable)
  end

  defp callable_descriptor_attrs(callable, key) do
    Heap.get_ctor_prop_desc(callable, key) ||
      %{writable: true, enumerable: true, configurable: true}
  end

  defp freeze_regexp(regexp, ref) do
    for key <- OwnProperty.descriptor_keys(regexp) do
      case InternalMethods.own_property(regexp, key) do
        :undefined ->
          :ok

        desc ->
          attrs = descriptor_attrs_from_object(desc)

          attrs =
            if Get.get(desc, "writable") == :undefined do
              Map.put(attrs, :configurable, false)
            else
              %{attrs | writable: false, configurable: false}
            end

          Heap.put_prop_desc(ref, key, attrs)
      end
    end

    Heap.prevent_extensions(regexp)
  end

  defp freeze_object({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        throw({:js_throw, Heap.make_error("Cannot freeze typed array", "TypeError")})

      %{proxy_target() => _target, proxy_handler() => _handler} ->
        freeze_proxy_object(obj, ref)

      _ ->
        freeze_ordinary_object(obj, ref)
    end
  end

  defp freeze_proxy_object(obj, ref) do
    unless prevent_extensions_object(obj) do
      throw({:js_throw, Heap.make_error("Cannot freeze object", "TypeError")})
    end

    for key <- OwnProperty.descriptor_keys(obj) do
      case InternalMethods.own_property(obj, key) do
        :undefined ->
          :ok

        desc ->
          raw_desc = %{"configurable" => false}

          raw_desc =
            if Get.get(desc, "writable") != :undefined do
              Map.put(raw_desc, "writable", false)
            else
              raw_desc
            end

          InternalMethods.define_own_property(obj, key, Heap.wrap(raw_desc), raw_desc)
      end
    end

    Heap.freeze(ref)
  end

  defp freeze_ordinary_object({:obj, ref} = obj, _ref) do
    unless seal_object(obj) do
      throw({:js_throw, Heap.make_error("Cannot freeze object", "TypeError")})
    end

    for key <- OwnProperty.descriptor_keys(obj) do
      desc =
        Heap.get_prop_desc(ref, key) || %{writable: true, enumerable: true, configurable: true}

      current = Heap.get_obj(ref, %{}) |> property_value_for_descriptor(key)

      if match?({:accessor, _, _}, current) do
        Heap.put_prop_desc(ref, key, Map.put(desc, :configurable, false))
      else
        Heap.put_prop_desc(ref, key, %{desc | writable: false, configurable: false})
      end
    end

    Heap.freeze(ref)
  end

  defp prevent_extensions_object({:obj, _} = obj), do: InternalMethods.prevent_extensions(obj)

  defp seal_object({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, proxy_handler() => _handler} ->
        seal_proxy_object(obj)

      _ ->
        for key <- OwnProperty.descriptor_keys(obj) do
          desc =
            Heap.get_prop_desc(ref, key) ||
              %{writable: true, enumerable: true, configurable: true}

          Heap.put_prop_desc(ref, key, Map.put(desc, :configurable, false))
        end

        prevent_extensions_object(obj)
    end
  end

  defp seal_proxy_object(obj) do
    unless prevent_extensions_object(obj) do
      throw({:js_throw, Heap.make_error("Cannot seal object", "TypeError")})
    end

    for key <- OwnProperty.descriptor_keys(obj) do
      desc = %{"configurable" => false}
      InternalMethods.define_own_property(obj, key, Heap.wrap(desc), desc)
    end

    true
  end

  defp frozen_object?({:obj, _ref} = obj) do
    not object_extensible?(obj) and
      Enum.all?(OwnProperty.descriptor_keys(obj), &frozen_descriptor?(obj, &1))
  end

  defp sealed_object?({:obj, _ref} = obj) do
    not object_extensible?(obj) and
      Enum.all?(OwnProperty.descriptor_keys(obj), &sealed_descriptor?(obj, &1))
  end

  defp seal_regexp(regexp, ref) do
    for key <- OwnProperty.descriptor_keys(regexp) do
      unless InternalMethods.own_property(regexp, key) == :undefined do
        regexp
        |> descriptor_attrs(key)
        |> Map.put(:configurable, false)
        |> then(&Heap.put_prop_desc(ref, key, &1))
      end
    end

    Heap.prevent_extensions(regexp)
  end

  defp descriptor_attrs(target, key) do
    case InternalMethods.own_property(target, key) do
      {:obj, _} = desc -> descriptor_attrs_from_object(desc)
      _ -> %{writable: true, enumerable: true, configurable: true}
    end
  end

  defp descriptor_attrs_from_object(desc) do
    %{
      writable: Get.get(desc, "writable") == true,
      enumerable: Get.get(desc, "enumerable") == true,
      configurable: Get.get(desc, "configurable") == true
    }
  end

  defp frozen_object_like?(target) do
    not Heap.extensible?(target) and
      Enum.all?(OwnProperty.descriptor_keys(target), &frozen_descriptor?(target, &1))
  end

  defp sealed_object_like?(target) do
    not Heap.extensible?(target) and
      Enum.all?(OwnProperty.descriptor_keys(target), &sealed_descriptor?(target, &1))
  end

  defp frozen_descriptor?(target, key) do
    case InternalMethods.own_property(target, key) do
      {:obj, _} = desc ->
        Get.get(desc, "configurable") == false and Get.get(desc, "writable") != true

      _ ->
        false
    end
  end

  defp sealed_descriptor?(target, key) do
    case InternalMethods.own_property(target, key) do
      {:obj, _} = desc -> Get.get(desc, "configurable") == false
      _ -> false
    end
  end

  defp object_extensible?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "isExtensible")

        if Value.nullish?(trap) do
          object_extensible?(target)
        else
          trap_result = Values.truthy?(Invocation.invoke_with_receiver(trap, [target], handler))
          target_result = object_extensible?(target)

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

  defp object_extensible?(_), do: true

  defp property_value_for_descriptor(map, key) when is_map(map), do: Map.get(map, key)
  defp property_value_for_descriptor(_data, _key), do: :undefined

  defp object_like?(value), do: Value.object_like?(value)
end
