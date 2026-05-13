defmodule QuickBEAM.VM.ObjectModel.OwnProperty do
  @moduledoc "Own-property predicates, key enumeration, and descriptor construction."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, Invocation, Runtime}

  alias QuickBEAM.VM.ObjectModel.{
    ArrayExotic,
    Get,
    PropertyDescriptor,
    PropertyKey,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime.TypedArray
  alias QuickBEAM.VM.Runtime.Date, as: JSDate

  def present?({:obj, ref}, key) do
    if key == proto() and Heap.get_prop_desc(ref, key) == nil do
      false
    else
      present?(ref, Heap.get_obj(ref, %{}), key)
    end
  end

  def present?(%QuickBEAM.VM.Function{} = target, key), do: callable_present?(target, key)

  def present?(map, key) when is_map(map) do
    raw_key = parse_array_index_key(key)

    Map.has_key?(map, key) or (raw_key != :error and Map.has_key?(map, raw_key)) or
      wrapped_string_index_present?(map, key)
  end

  def present?(list, key) when is_list(list) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 -> idx < length(list)
      _ -> key == "length"
    end
  end

  def present?({:qb_arr, arr}, key) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 -> idx < :array.size(arr)
      _ -> key == "length"
    end
  end

  def present?(string, key) when is_binary(string) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 -> idx < Get.string_length(string)
      _ -> key == "length"
    end
  end

  def present?({:builtin, "Object", _}, "prototype"), do: true

  def present?({:builtin, "Object", _} = builtin, "assign") do
    not match?(%{"assign" => :deleted}, Heap.get_ctor_statics(builtin))
  end

  def present?({:builtin, _, _} = builtin, key) when key in ["name", "length"] do
    not match?(%{^key => :deleted}, Heap.get_ctor_statics(builtin))
  end

  def present?({:builtin, _, _} = builtin, key) do
    case Heap.get_ctor_statics(builtin) do
      %{^key => :deleted} ->
        false

      statics ->
        Map.has_key?(statics, key) or module_static_present?(Map.get(statics, :__module__), key)
    end
  end

  def present?(target, key) when is_tuple(target) or is_struct(target),
    do: callable_present?(target, key)

  def present?(_target, _key), do: false

  defp callable_present?(target, key) do
    case Heap.get_ctor_statics(target) do
      %{^key => :deleted} -> false
      statics -> Map.has_key?(statics, key) or virtual_callable_property?(target, key)
    end
  end

  defp virtual_callable_property?(target, "prototype"), do: has_prototype?(target)
  defp virtual_callable_property?(target, "length"), do: not deleted_static?(target, "length")
  defp virtual_callable_property?(target, "name"), do: not deleted_static?(target, "name")
  defp virtual_callable_property?(_, _), do: false

  defp has_prototype?(%QuickBEAM.VM.Function{has_prototype: true}), do: true
  defp has_prototype?({:closure, _, %QuickBEAM.VM.Function{has_prototype: true}}), do: true
  defp has_prototype?(_), do: false

  defp deleted_static?(target, key),
    do: Map.get(Heap.get_ctor_statics(target), key) == :deleted

  defp module_static_present?(module, key) when is_atom(module) do
    module_static_value(module, key) != :undefined
  end

  defp module_static_present?(_module, _key), do: false

  defp module_static_value(module, key) when is_atom(module) do
    if function_exported?(module, :static_property, 1),
      do: module.static_property(key),
      else: :undefined
  end

  defp module_static_value(_module, _key), do: :undefined

  defp present?(ref, data, key) when is_list(data) do
    present_array_property?(ref, key)
  end

  defp present?(ref, {:qb_arr, _}, key) do
    present_array_property?(ref, key)
  end

  defp present?(_ref, data, key), do: present?(data, key)

  defp present_array_property?(ref, key) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 ->
        Heap.array_get(ref, idx) != :undefined or Heap.get_prop_desc(ref, to_string(key)) != nil

      _ ->
        key == "length" or Heap.get_array_prop(ref, to_string(key)) != :undefined or
          Heap.get_prop_desc(ref, to_string(key)) != nil
    end
  end

  def enumerable?({:obj, ref}, key),
    do: not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))

  def enumerable?({:builtin, "Object", _}, "assign"), do: false
  def enumerable?({:builtin, _, _}, key) when key in ["length", "name"], do: false

  def enumerable?({:builtin, _, _} = target, key) do
    case descriptor(target, key) do
      {:obj, desc_ref} -> QuickBEAM.VM.ObjectModel.Get.get({:obj, desc_ref}, "enumerable") == true
      _ -> false
    end
  end

  def enumerable?(target, key)
      when key in ["length", "name", "prototype"] and (is_tuple(target) or is_struct(target)),
      do: false

  def enumerable?(string, key) when is_binary(string), do: key != "length"
  def enumerable?(_target, _key), do: true

  def descriptor_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "ownKeys")

        if trap == :undefined or trap == nil do
          descriptor_keys(target)
        else
          trap
          |> Runtime.call_callback([target])
          |> Heap.to_list()
        end

      {:qb_arr, arr} ->
        array_indices(:array.size(arr)) ++ array_property_keys(ref) ++ ["length"]

      list when is_list(list) ->
        array_indices(list) ++ array_property_keys(ref) ++ ["length"]

      map when is_map(map) ->
        ordered_map_keys(map)

      _ ->
        []
    end
  end

  def descriptor_keys(%QuickBEAM.VM.Function{} = fun), do: callable_descriptor_keys(fun)

  def descriptor_keys({:closure, _, %QuickBEAM.VM.Function{}} = fun),
    do: callable_descriptor_keys(fun)

  def descriptor_keys({:builtin, _, _} = builtin), do: callable_descriptor_keys(builtin)
  def descriptor_keys({:bound, _, _, _, _} = bound), do: callable_descriptor_keys(bound)
  def descriptor_keys(_), do: []

  defp callable_descriptor_keys(callable) do
    statics = Heap.get_ctor_statics(callable)
    explicit_keys = statics |> Map.keys() |> Enum.filter(&callable_descriptor_key?/1)
    builtin_order = ["length", "name", "prototype"]

    (builtin_order ++ (explicit_keys -- builtin_order))
    |> Enum.uniq()
    |> Enum.filter(&present?(callable, &1))
  end

  defp callable_descriptor_key?(key) when is_binary(key),
    do: not (String.starts_with?(key, "__") and String.ends_with?(key, "__"))

  defp callable_descriptor_key?(_key), do: false

  defp ordered_map_keys(map) do
    insertion_order =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> []
      end

    virtual_keys = wrapped_string_index_keys(map)
    keys = virtual_keys ++ insertion_order ++ (Map.keys(map) -- (insertion_order -- virtual_keys))
    keys = Enum.reject(keys, &descriptor_internal_key?/1)

    {indexes, rest} = Enum.split_with(keys, &array_index_key?/1)
    {strings, symbols} = Enum.split_with(rest, &is_binary/1)

    Enum.sort_by(indexes, &array_index_value/1) ++ strings ++ symbols
  end

  defp wrapped_string_index_present?(map, key) when is_map(map) do
    with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(map, :string),
         idx when is_integer(idx) <- parse_array_index_key(key) do
      idx < Get.string_length(string)
    else
      _ -> false
    end
  end

  defp wrapped_string_index_present?(_map, _key), do: false

  defp wrapped_string_index_keys(map) when is_map(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, string} when is_binary(string) -> array_indices(Get.string_length(string))
      _ -> []
    end
  end

  defp wrapped_string_index_keys(_map), do: []

  defp array_index_key?(key), do: match?({:ok, _}, PropertyKey.array_index(key))

  defp array_index_value(key) do
    {:ok, idx} = PropertyKey.array_index(key)
    idx
  end

  def descriptor({:obj, ref}, key) do
    prop_name = PropertyKey.normalize(key)
    data = Heap.get_obj(ref, %{})

    cond do
      is_map(data) and Map.has_key?(data, proxy_target()) ->
        proxy_descriptor(data, prop_name)

      is_list(data) or match?({:qb_arr, _}, data) ->
        ArrayExotic.descriptor(ref, data, prop_name)

      is_map(data) and Map.get(data, typed_array()) ->
        typed_array_descriptor({:obj, ref}, prop_name)

      is_map(data) ->
        map_descriptor(ref, data, prop_name)

      true ->
        :undefined
    end
  end

  def descriptor({:builtin, name, map} = builtin, key) do
    prop_key = if is_binary(key), do: key, else: key
    statics = Heap.get_ctor_statics(builtin)
    module = Map.get(statics, :__module__)

    fallback =
      cond do
        is_map(map) and Map.has_key?(map, prop_key) ->
          Map.get(map, prop_key)

        module_static_value(module, prop_key) != :undefined ->
          module_static_value(module, prop_key)

        prop_key == "length" and is_function(map) ->
          builtin_function_length(map, name)

        true ->
          builtin_descriptor_value(name, prop_key)
      end

    case Map.get(statics, prop_key, fallback) do
      :deleted ->
        :undefined

      {:accessor, getter, setter} ->
        PropertyDescriptor.accessor_object(
          getter,
          setter,
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)
        )

      nil ->
        :undefined

      val ->
        PropertyDescriptor.data_object(
          val,
          Heap.get_prop_desc(builtin, prop_key) || builtin_descriptor_attrs(module, prop_key, val)
        )
    end
  end

  def descriptor(%QuickBEAM.VM.Function{} = target, key) do
    callable_descriptor(target, key)
  end

  def descriptor({:closure, _, %QuickBEAM.VM.Function{}} = target, key) do
    callable_descriptor(target, key)
  end

  def descriptor({:bound, _, _, _, _} = target, key) do
    callable_descriptor(target, key)
  end

  def descriptor(target, key) when is_tuple(target) or is_struct(target) do
    prop_key = if is_binary(key), do: key, else: key

    case Map.fetch(Heap.get_ctor_statics(target), prop_key) do
      {:ok, {:accessor, getter, setter}} ->
        PropertyDescriptor.accessor_object(
          getter,
          setter,
          callable_prop_desc(target, prop_key) ||
            PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
        )

      {:ok, value} when value != :deleted ->
        PropertyDescriptor.data_object(
          value,
          callable_prop_desc(target, prop_key) ||
            PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)
        )

      _ ->
        :undefined
    end
  end

  def descriptor(_target, _key), do: :undefined

  defp callable_descriptor(target, key) do
    prop_key = if is_binary(key), do: key, else: key

    case Map.fetch(Heap.get_ctor_statics(target), prop_key) do
      {:ok, value} when value != :deleted ->
        PropertyDescriptor.data_object(
          value,
          callable_prop_desc(target, prop_key) || builtin_descriptor_attrs(prop_key)
        )

      {:ok, :deleted} ->
        :undefined

      _ when prop_key == "length" ->
        PropertyDescriptor.data_object(
          callable_length(target),
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)
        )

      _ when prop_key == "name" ->
        PropertyDescriptor.data_object(
          callable_name(target),
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)
        )

      _ ->
        :undefined
    end
  end

  defp callable_length(%QuickBEAM.VM.Function{defined_arg_count: n}), do: n
  defp callable_length({:closure, _, %QuickBEAM.VM.Function{defined_arg_count: n}}), do: n
  defp callable_length({:bound, len, _, _, _}), do: len
  defp callable_length(_), do: 0

  defp callable_name(%QuickBEAM.VM.Function{name: n}) when is_binary(n), do: n
  defp callable_name({:closure, _, %QuickBEAM.VM.Function{name: n}}) when is_binary(n), do: n
  defp callable_name({:bound, _, {:builtin, n, _}, _, _}), do: n
  defp callable_name({:builtin, n, _}) when is_binary(n), do: n
  defp callable_name(_), do: ""

  defp callable_prop_desc(target, prop_key) do
    Heap.get_prop_desc(target, prop_key) || Heap.get_ctor_prop_desc(target, prop_key)
  end

  defp typed_array_descriptor(obj, prop_name) do
    case PropertyKey.array_index(prop_name) do
      {:ok, idx} ->
        val = TypedArray.get_element(obj, idx)

        if val == :undefined do
          :undefined
        else
          immutable = TypedArray.immutable?(obj)

          PropertyDescriptor.data_object(
            val,
            PropertyDescriptor.attrs(
              writable: not immutable,
              enumerable: true,
              configurable: not immutable
            )
          )
        end

      _ ->
        :undefined
    end
  end

  defp map_descriptor(ref, data, prop_name) do
    prop_desc = Heap.get_prop_desc(ref, prop_name)
    wrapped_string_length = wrapped_string_length_descriptor(data, prop_name)

    case Map.fetch(data, prop_name) do
      _ when prop_name == proto() and prop_desc == nil ->
        :undefined

      _ when wrapped_string_length != nil ->
        wrapped_string_length

      :error ->
        wrapped_string_index_descriptor(data, prop_name) ||
          prototype_method_descriptor(data, prop_name)

      {:ok, {:accessor, getter, setter}} ->
        desc =
          Heap.get_prop_desc(ref, prop_name) ||
            PropertyDescriptor.attrs(writable: false, enumerable: true, configurable: true)

        PropertyDescriptor.accessor_object(getter, setter, desc)

      {:ok, val} ->
        data_desc =
          Heap.get_prop_desc(ref, prop_name) || default_map_descriptor_attrs(data, prop_name, val)

        PropertyDescriptor.data_object(val, data_desc)
    end
  end

  defp wrapped_string_length_descriptor(data, "length") when is_map(data) do
    case WrappedPrimitive.value(data, :string) do
      {:ok, string} when is_binary(string) ->
        PropertyDescriptor.data_object(
          QuickBEAM.VM.ObjectModel.Get.string_length(string),
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
        )

      _ ->
        nil
    end
  end

  defp wrapped_string_length_descriptor(_data, _prop_name), do: nil

  defp wrapped_string_index_descriptor(data, prop_name) when is_map(data) do
    with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(data, :string),
         {idx, ""} when idx >= 0 <- Integer.parse(prop_name),
         true <- idx < Get.string_length(string) do
      PropertyDescriptor.data_object(
        QuickBEAM.VM.Runtime.String.utf16_code_unit_at(string, idx),
        PropertyDescriptor.attrs(writable: false, enumerable: true, configurable: false)
      )
    else
      _ -> nil
    end
  end

  defp wrapped_string_index_descriptor(_data, _prop_name), do: nil

  defp prototype_method_descriptor(%{"constructor" => {:builtin, "Date", _}}, prop_name) do
    case JSDate.proto_property(prop_name) do
      :undefined ->
        :undefined

      val ->
        PropertyDescriptor.data_object(
          val,
          PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)
        )
    end
  end

  defp prototype_method_descriptor(_data, _prop_name), do: :undefined

  defp default_map_descriptor_attrs(
         %{"constructor" => {:builtin, _name, _}},
         "constructor",
         _val
       ),
       do: PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)

  defp default_map_descriptor_attrs(_data, _prop_name, _val),
    do: PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)

  defp builtin_descriptor_value("Object", "prototype"), do: Runtime.global_class_proto("Object")

  defp builtin_descriptor_value("Object", "assign"),
    do: QuickBEAM.VM.Runtime.Object.static_property("assign")

  defp builtin_descriptor_value(name, "name"), do: name

  defp builtin_descriptor_value(name, "length") do
    case QuickBEAM.VM.Builtin.named_meta(name) do
      %QuickBEAM.VM.Builtin.Meta{length: length} -> length
      _ -> nil
    end
  end

  defp builtin_descriptor_value(_, _), do: nil

  defp builtin_function_length(fun, name) when is_function(fun) do
    case QuickBEAM.VM.Builtin.named_meta(name) do
      %QuickBEAM.VM.Builtin.Meta{length: length} ->
        length

      _ ->
        {:arity, arity} = Function.info(fun, :arity)
        max(arity - 2, 0)
    end
  end

  defp builtin_function_length(_, _), do: nil

  defp builtin_descriptor_attrs("prototype"),
    do: PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)

  defp builtin_descriptor_attrs("assign"),
    do: PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)

  defp builtin_descriptor_attrs(key) when key in ["name", "length"],
    do: PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)

  defp builtin_descriptor_attrs(_),
    do: PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)

  defp builtin_descriptor_attrs(module, key, value) do
    cond do
      key in ["prototype", "assign", "name", "length"] ->
        builtin_descriptor_attrs(key)

      QuickBEAM.VM.Builtin.callable?(value) ->
        PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)

      module != nil or constant_property_name?(key) ->
        PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)

      true ->
        PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)
    end
  end

  defp constant_property_name?(key) when is_binary(key), do: String.upcase(key) == key
  defp constant_property_name?(_key), do: false

  defp proxy_descriptor(proxy_map, prop_name) do
    target = Map.fetch!(proxy_map, proxy_target())
    handler = Map.fetch!(proxy_map, proxy_handler())
    trap = Get.get(handler, "getOwnPropertyDescriptor")

    if trap == :undefined or trap == nil do
      descriptor(target, prop_name)
    else
      result = Invocation.invoke_callback_or_throw(trap, [target, prop_name])
      validate_proxy_descriptor_result(target, prop_name, result)
    end
  end

  defp validate_proxy_descriptor_result(target, prop_name, :undefined) do
    case target_descriptor_flags(target, prop_name) do
      %{configurable: false} -> proxy_descriptor_invariant_error()
      _ -> :undefined
    end
  end

  defp validate_proxy_descriptor_result(target, prop_name, {:obj, result_ref} = result) do
    result_desc = Heap.get_obj(result_ref, %{})

    cond do
      not target_extensible?(target) and target_descriptor_flags(target, prop_name) == nil ->
        proxy_descriptor_invariant_error()

      Map.get(result_desc, "configurable") == false and
          not match?(%{configurable: false}, target_descriptor_flags(target, prop_name)) ->
        proxy_descriptor_invariant_error()

      true ->
        result
    end
  end

  defp validate_proxy_descriptor_result(_target, _prop_name, _result), do: :undefined

  defp target_descriptor_flags({:obj, ref} = target, prop_name) do
    Heap.get_prop_desc(ref, prop_name) ||
      if present?(target, prop_name) do
        PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)
      end
  end

  defp target_descriptor_flags(_target, _prop_name), do: nil

  defp target_extensible?({:obj, ref}), do: Heap.extensible?(ref)
  defp target_extensible?(_target), do: true

  defp proxy_descriptor_invariant_error do
    throw(
      {:js_throw,
       Heap.make_error("proxy getOwnPropertyDescriptor trap violates invariant", "TypeError")}
    )
  end

  defp descriptor_internal_key?(key)
       when key in [key_order(), proto(), proxy_target(), proxy_handler()],
       do: true

  defp descriptor_internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp descriptor_internal_key?(_), do: false

  defp array_indices(size) when is_integer(size) do
    if size <= 0, do: [], else: Enum.map(0..(size - 1), &Integer.to_string/1)
  end

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end

  defp array_property_keys(ref) do
    ref
    |> Heap.get_array_props()
    |> Map.keys()
    |> Enum.reject(&(&1 == "length" or descriptor_internal_key?(&1)))
  end

  defp parse_array_index_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> idx
      _ -> :error
    end
  end

  defp parse_array_index_key(_), do: :error
end
