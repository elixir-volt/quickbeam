defmodule QuickBEAM.VM.ObjectModel.OwnProperty do
  @moduledoc "Own-property predicates, key enumeration, and descriptor construction."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Builtin, Heap, Invocation, JSThrow, Runtime}
  alias QuickBEAM.VM.Execution.RegexpState

  alias QuickBEAM.VM.ObjectModel.{
    ArrayExotic,
    Get,
    PropertyDescriptor,
    PropertyKey,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.TypedArray

  def present?({:obj, ref}, key) do
    cond do
      key in ["caller", "arguments"] and Heap.get_func_proto() == {:obj, ref} ->
        Heap.get_prop_desc(ref, key) != :deleted

      key == "length" and array_prototype_object?(Heap.get_obj_raw(ref)) ->
        true

      match?(%{^key => _}, Heap.get_regexp_result(ref) || %{}) ->
        true

      key == proto() and Heap.get_prop_desc(ref, key) == nil ->
        false

      true ->
        present?(ref, Heap.get_obj(ref, %{}), key)
    end
  end

  def present?(%QuickBEAM.VM.Function{} = target, key), do: callable_present?(target, key)

  def present?(map, key) when is_map(map) do
    raw_key = integer_property_key(key)

    Map.has_key?(map, key) or (raw_key != :error and Map.has_key?(map, raw_key)) or
      wrapped_string_length_present?(map, key) or wrapped_string_index_present?(map, key)
  end

  def present?(list, key) when is_list(list) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < length(list)
      :error -> key == "length"
    end
  end

  def present?({:qb_arr, arr}, key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < :array.size(arr)
      :error -> key == "length"
    end
  end

  def present?(string, key) when is_binary(string) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < Get.string_length(string)
      :error -> key == "length"
    end
  end

  def present?({:builtin, "Object", _}, "prototype"), do: true

  def present?({:regexp, _, _, ref}, key), do: RegexpState.has_property?(ref, key)

  def present?({:builtin, "Object", _} = builtin, "assign") do
    not match?(%{"assign" => :deleted}, Heap.get_ctor_statics(builtin))
  end

  def present?({:builtin, _, _} = builtin, key) when key in ["name", "length"] do
    Builtin.callable?(builtin) and not match?(%{^key => :deleted}, Heap.get_ctor_statics(builtin))
  end

  def present?({:builtin, _, map} = builtin, key) do
    case Heap.get_ctor_statics(builtin) do
      %{^key => :deleted} ->
        false

      statics ->
        (is_map(map) and Map.has_key?(map, key)) or Map.has_key?(statics, key) or
          module_static_present?(Map.get(statics, :__module__), key)
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
  defp has_prototype?(%QuickBEAM.VM.Function{func_kind: 1}), do: true
  defp has_prototype?({:closure, _, %QuickBEAM.VM.Function{func_kind: 1}}), do: true
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

  defp present?(ref, %{typed_array() => true}, key) do
    case typed_array_index_key(key) do
      idx when is_integer(idx) ->
        not TypedArray.out_of_bounds?({:obj, ref}) and idx < typed_array_index_count(ref)

      nil ->
        present?(Heap.get_obj(ref, %{}), key)
    end
  end

  defp present?(_ref, data, key), do: present?(data, key)

  defp typed_array_index_count(ref) do
    state = Heap.get_obj(ref, %{})

    if Map.get(state, "__length_tracking__") do
      case Map.get(state, "buffer") do
        {:obj, buffer_ref} ->
          buffer = Heap.get_obj(buffer_ref, %{})
          byte_length = byte_size(Map.get(buffer, buffer(), Map.get(state, buffer(), <<>>)))
          byte_offset = Map.get(state, "byteOffset", 0)
          element_size = TypedArray.elem_size(Map.get(state, type_key(), :uint8))
          div(max(byte_length - byte_offset, 0), element_size)

        _ ->
          TypedArray.element_count({:obj, ref})
      end
    else
      Map.get(state, "__fixed_length__", TypedArray.element_count({:obj, ref}))
    end
  end

  defp typed_array_index_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx
      :error -> nil
    end
  end

  defp present_array_property?(ref, key) when is_binary(key) or is_integer(key) do
    prop_key = to_string(key)

    case PropertyKey.array_index(prop_key) do
      {:ok, idx} ->
        Heap.array_get(ref, idx) != :undefined or Heap.get_array_prop(ref, prop_key) != :undefined or
          Heap.get_prop_desc(ref, prop_key) != nil

      :error ->
        key == "length" or Heap.get_array_prop(ref, prop_key) != :undefined or
          Heap.get_prop_desc(ref, prop_key) != nil
    end
  end

  defp present_array_property?(ref, key) do
    Heap.get_array_prop(ref, key) != :undefined or Heap.get_prop_desc(ref, key) != nil
  end

  def enumerable?({:obj, ref}, key),
    do: not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))

  def enumerable?({:builtin, "Object", _}, "assign"), do: false

  def enumerable?({:builtin, _, _} = target, key) do
    case descriptor(target, key) do
      {:obj, desc_ref} -> QuickBEAM.VM.ObjectModel.Get.get({:obj, desc_ref}, "enumerable") == true
      _ -> false
    end
  end

  def enumerable?(target, key)
      when key in ["length", "name", "prototype"] and (is_tuple(target) or is_struct(target)) do
    case descriptor(target, key) do
      {:obj, desc_ref} -> QuickBEAM.VM.ObjectModel.Get.get({:obj, desc_ref}, "enumerable") == true
      _ -> false
    end
  end

  def enumerable?(string, key) when is_binary(string), do: key != "length"
  def enumerable?(_target, _key), do: true

  def descriptor_keys(target), do: own_keys(target)

  def own_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "ownKeys")

        if trap == :undefined or trap == nil do
          own_keys(target)
        else
          trap
          |> Runtime.call_callback([target])
          |> proxy_own_keys_list()
          |> validate_proxy_own_keys_invariant(target)
        end

      {:qb_arr, arr} ->
        array_present_indices(ref, :array.size(arr)) ++ ["length"] ++ array_property_keys(ref)

      list when is_list(list) ->
        array_present_indices(ref, length(list)) ++ ["length"] ++ array_property_keys(ref)

      map when is_map(map) ->
        ordered_map_keys(map)

      _ ->
        []
    end
  end

  def own_keys(%QuickBEAM.VM.Function{} = fun), do: callable_descriptor_keys(fun)

  def own_keys({:closure, _, %QuickBEAM.VM.Function{}} = fun),
    do: callable_descriptor_keys(fun)

  def own_keys({:builtin, _, map} = builtin) do
    if Builtin.callable?(builtin),
      do: callable_descriptor_keys(builtin, map),
      else: builtin_namespace_descriptor_keys(builtin, map)
  end

  def own_keys({:bound, _, _, _, _} = bound), do: callable_descriptor_keys(bound)

  def own_keys({:regexp, _, _, ref}) do
    keys = RegexpState.get(ref) |> Map.keys() |> Enum.reject(&descriptor_internal_key?/1)
    (["lastIndex"] ++ (Enum.reverse(keys) -- ["lastIndex"])) |> Enum.uniq()
  end

  def own_keys(string) when is_binary(string),
    do: array_indices(Get.string_length(string)) ++ ["length"]

  def own_keys(_), do: []

  defp builtin_namespace_descriptor_keys(builtin, inline_map) do
    statics = Heap.get_ctor_statics(builtin)
    static_keys = statics |> Map.keys() |> Enum.filter(&callable_descriptor_key?/1)
    inline_keys = if is_map(inline_map), do: Map.keys(inline_map), else: []
    module_keys = module_static_keys(Map.get(statics, :__module__))

    (static_keys ++ inline_keys ++ module_keys)
    |> Enum.uniq()
    |> Enum.filter(&(callable_descriptor_key?(&1) and present?(builtin, &1)))
  end

  defp callable_descriptor_keys(callable, inline_map \\ nil) do
    statics = Heap.get_ctor_statics(callable)

    static_keys = statics |> Map.keys() |> Enum.filter(&callable_descriptor_key?/1)
    inline_keys = if is_map(inline_map), do: Map.keys(inline_map), else: []
    module_keys = module_static_keys(Map.get(statics, :__module__))

    explicit_keys =
      Enum.filter(static_keys ++ inline_keys ++ module_keys, &callable_descriptor_key?/1)

    builtin_order = ["length", "name", "prototype"]

    (builtin_order ++ (explicit_keys -- builtin_order))
    |> Enum.uniq()
    |> Enum.filter(&present?(callable, &1))
  end

  defp callable_descriptor_key?(key) when is_binary(key),
    do: not (String.starts_with?(key, "__") and String.ends_with?(key, "__"))

  defp callable_descriptor_key?({:symbol, _}), do: true
  defp callable_descriptor_key?(_key), do: false

  defp module_static_keys(module) when is_atom(module) do
    if function_exported?(module, :static_property_names, 0),
      do: module.static_property_names(),
      else: []
  end

  defp module_static_keys(_module), do: []

  def validate_proxy_own_keys_invariant(trap_keys, target) do
    target_keys = own_keys(target)

    missing_key =
      Enum.find(target_keys, fn key ->
        match?(%{configurable: false}, target_prop_desc(target, key)) and key not in trap_keys
      end)

    cond do
      Enum.uniq(trap_keys) != trap_keys ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      missing_key ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      non_extensible_key_mismatch?(target, target_keys, trap_keys) ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      true ->
        trap_keys
    end
  end

  defp non_extensible_key_mismatch?({:obj, ref}, target_keys, trap_keys),
    do: not Heap.extensible?(ref) and Enum.sort(target_keys) != Enum.sort(trap_keys)

  defp non_extensible_key_mismatch?(_target, _target_keys, _trap_keys), do: false

  defp proxy_own_keys_list(result) do
    length = Get.get(result, "length")

    if is_integer(length) and length > 0 do
      for index <- 0..(length - 1), do: Get.get(result, Integer.to_string(index))
    else
      []
    end
  end

  defp target_prop_desc({:obj, ref}, key), do: Heap.get_prop_desc(ref, key)
  defp target_prop_desc(_target, _key), do: nil

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

    Enum.sort_by(indexes, &array_index_value/1) ++ strings ++ Enum.reverse(symbols)
  end

  defp wrapped_string_length_present?(map, "length") when is_map(map) do
    match?({:ok, string} when is_binary(string), WrappedPrimitive.value(map, :string))
  end

  defp wrapped_string_length_present?(_map, _key), do: false

  defp wrapped_string_index_present?(map, key) when is_map(map) do
    with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(map, :string),
         {:ok, idx} <- PropertyKey.array_index(key) do
      idx < Get.string_length(string)
    else
      _ -> false
    end
  end

  defp wrapped_string_index_keys(map) when is_map(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, string} when is_binary(string) ->
        array_indices(Get.string_length(string)) ++ ["length"]

      _ ->
        []
    end
  end

  defp integer_property_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> :error
    end
  end

  defp array_index_key?(key), do: match?({:ok, _}, PropertyKey.array_index(key))

  defp array_index_value(key) do
    {:ok, idx} = PropertyKey.array_index(key)
    idx
  end

  def descriptor({:obj, ref}, key) do
    prop_name = PropertyKey.normalize(key)
    data = Heap.get_obj(ref, %{})

    cond do
      match?(%{^prop_name => _}, Heap.get_regexp_result(ref) || %{}) ->
        %{^prop_name => value} = Heap.get_regexp_result(ref)

        PropertyDescriptor.data_object(
          value,
          PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)
        )

      prop_name in ["caller", "arguments"] and Heap.get_func_proto() == {:obj, ref} and
          Heap.get_prop_desc(ref, prop_name) != :deleted ->
        thrower = Heap.throw_type_error_intrinsic()

        PropertyDescriptor.accessor_object(
          thrower,
          thrower,
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)
        )

      array_prototype_object?(data) and prop_name == "length" ->
        array_prototype_length_descriptor(ref, data)

      is_map(data) and Map.get(data, "__proxy_revoked__") == true and
          Map.has_key?(data, proxy_target()) ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

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

  def descriptor(string, key) when is_binary(string) do
    prop_name = PropertyKey.normalize(key)

    cond do
      prop_name == "length" ->
        PropertyDescriptor.data_object(
          Get.string_length(string),
          PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
        )

      true ->
        with {:ok, idx} <- PropertyKey.array_index(prop_name),
             true <- idx < Get.string_length(string) do
          PropertyDescriptor.data_object(
            QuickBEAM.VM.Runtime.String.utf16_code_unit_at(string, idx),
            PropertyDescriptor.attrs(writable: false, enumerable: true, configurable: false)
          )
        else
          _ -> :undefined
        end
    end
  end

  def descriptor({:regexp, _, _, ref}, key) do
    case RegexpState.fetch(ref, key) do
      {:ok, {:accessor, getter, setter}} ->
        PropertyDescriptor.accessor_object(
          getter,
          setter,
          Heap.get_prop_desc(ref, key) ||
            PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
        )

      {:ok, value} ->
        default_attrs =
          if key == "lastIndex" do
            PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: false)
          else
            PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: true)
          end

        PropertyDescriptor.data_object(value, Heap.get_prop_desc(ref, key) || default_attrs)

      :error ->
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
          Heap.get_prop_desc(builtin, prop_key) || Heap.get_ctor_prop_desc(builtin, prop_key) ||
            builtin_descriptor_attrs(module, prop_key, val)
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

  defp array_prototype_object?(raw) do
    cond do
      Heap.shape?(raw) ->
        offsets = Heap.shape_offsets(raw)

        Map.has_key?(offsets, "constructor") and Map.has_key?(offsets, "push") and
          Map.has_key?(offsets, "pop")

      is_map(raw) ->
        Map.has_key?(raw, "constructor") and Map.has_key?(raw, "push") and
          Map.has_key?(raw, "pop")

      true ->
        false
    end
  end

  defp array_prototype_length_descriptor(ref, data) do
    value =
      case Heap.get_array_prop(ref, "length") do
        len when is_integer(len) -> len
        _ -> array_prototype_index_length(data)
      end

    desc =
      Heap.get_prop_desc(ref, "length") ||
        PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: false)

    PropertyDescriptor.data_object(value, desc)
  end

  defp array_prototype_index_length(raw) when is_tuple(raw),
    do: array_prototype_index_length(Map.keys(Heap.shape_offsets(raw)))

  defp array_prototype_index_length(map) when is_map(map),
    do: array_prototype_index_length(Map.keys(map))

  defp array_prototype_index_length(keys) do
    Enum.reduce(keys, 0, fn key, length ->
      case PropertyKey.array_index(key) do
        {:ok, index} -> max(length, index + 1)
        :error -> length
      end
    end)
  end

  defp callable_descriptor(target, key) do
    prop_key = if is_binary(key), do: key, else: key

    case Map.fetch(Heap.get_ctor_statics(target), prop_key) do
      {:ok, {:accessor, getter, setter}} ->
        PropertyDescriptor.accessor_object(
          getter,
          setter,
          callable_prop_desc(target, prop_key) || builtin_descriptor_attrs(prop_key)
        )

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
          callable_prop_desc(target, prop_key) ||
            PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)
        )

      _ when prop_key == "name" ->
        PropertyDescriptor.data_object(
          callable_name(target),
          callable_prop_desc(target, prop_key) ||
            PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: true)
        )

      _ when prop_key == "prototype" ->
        if has_prototype?(target) do
          PropertyDescriptor.data_object(
            Heap.get_or_create_prototype(target),
            callable_prop_desc(target, prop_key) ||
              PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: false)
          )
        else
          :undefined
        end

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
         {:ok, idx} <- PropertyKey.array_index(prop_name),
         true <- idx < Get.string_length(string) do
      PropertyDescriptor.data_object(
        QuickBEAM.VM.Runtime.String.utf16_code_unit_at(string, idx),
        PropertyDescriptor.attrs(writable: false, enumerable: true, configurable: false)
      )
    else
      _ -> nil
    end
  end

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
       when key in [key_order(), proto(), proxy_target(), proxy_handler(), :__internal_proto__],
       do: true

  defp descriptor_internal_key?({:internal, _}), do: true

  defp descriptor_internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp descriptor_internal_key?(_), do: false

  defp array_indices(size) when is_integer(size) do
    if size <= 0, do: [], else: Enum.map(0..(size - 1), &Integer.to_string/1)
  end

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end

  defp array_present_indices(_ref, size) when size <= 0, do: []

  defp array_present_indices(ref, size) do
    0..(size - 1)
    |> Enum.filter(fn idx ->
      key = Integer.to_string(idx)

      Heap.array_get(ref, idx) != :undefined or Heap.get_array_prop(ref, key) != :undefined or
        Heap.get_prop_desc(ref, key) != nil
    end)
    |> Enum.map(&Integer.to_string/1)
  end

  defp array_property_keys(ref) do
    keys =
      ref
      |> Heap.get_array_props()
      |> Map.keys()
      |> Enum.reject(&(&1 == "length" or descriptor_internal_key?(&1)))

    {strings, symbols} = Enum.split_with(keys, &is_binary/1)
    strings ++ symbols
  end
end
