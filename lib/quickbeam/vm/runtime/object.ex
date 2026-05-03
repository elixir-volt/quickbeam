defmodule QuickBEAM.VM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1]
  alias QuickBEAM.VM.Bytecode
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.TypedArray

  @doc "Builds prototype data for object static methods."
  def build_prototype do
    ref = make_ref()

    Heap.put_obj(
      ref,
      object heap: false do
        method "toString" do
          object_to_string(this)
        end

        method "valueOf" do
          object_value_of(this)
        end

        method "hasOwnProperty" do
          has_own_property(args, this)
        end

        method "isPrototypeOf" do
          prototype_of?(args, this)
        end

        method "propertyIsEnumerable" do
          property_enumerable?(args, this)
        end
      end
    )

    proto = {:obj, ref}

    for key <- [
          "toString",
          "valueOf",
          "hasOwnProperty",
          "isPrototypeOf",
          "propertyIsEnumerable",
          "constructor"
        ] do
      Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true, writable: true})
    end

    Heap.put_object_prototype(proto)
    proto
  end

  defp has_own_property([_key | _], target) when target in [nil, :undefined] do
    throw({:js_throw, Heap.make_error("hasOwnProperty called on null or undefined", "TypeError")})
  end

  defp has_own_property([key | _], target) do
    prop_name = if is_binary(key) or is_symbol(key), do: key, else: Values.stringify(key)
    own_property?(target, prop_name)
  end

  defp has_own_property(_, _), do: false

  defp property_enumerable?([_key | _], target) when target in [nil, :undefined] do
    throw(
      {:js_throw,
       Heap.make_error("propertyIsEnumerable called on null or undefined", "TypeError")}
    )
  end

  defp property_enumerable?([key | _], target) do
    prop_name = if is_binary(key) or is_symbol(key), do: key, else: Values.stringify(key)
    own_property?(target, prop_name) and enumerable_property?(target, prop_name)
  end

  defp property_enumerable?(_, _), do: false

  defp object_value_of(value) when value in [nil, :undefined] do
    throw(
      {:js_throw,
       Heap.make_error("Object.prototype.valueOf called on null or undefined", "TypeError")}
    )
  end

  defp object_value_of({:obj, _} = obj), do: obj

  defp object_value_of(value) when is_binary(value),
    do: Heap.wrap(%{"__wrapped_string__" => value})

  defp object_value_of(value) when is_number(value),
    do: Heap.wrap(%{"__wrapped_number__" => value})

  defp object_value_of(value) when is_boolean(value),
    do: Heap.wrap(%{"__wrapped_boolean__" => value})

  defp object_value_of({:symbol, _, _} = value), do: Heap.wrap(%{"__wrapped_symbol__" => value})
  defp object_value_of({:symbol, _} = value), do: Heap.wrap(%{"__wrapped_symbol__" => value})
  defp object_value_of(value), do: value

  defp prototype_of?([{:obj, ref} | _], {:obj, proto_ref}) do
    prototype_chain_contains?(Map.get(Heap.get_obj(ref, %{}), proto()), proto_ref)
  end

  defp prototype_of?(_, _), do: false

  defp prototype_chain_contains?({:obj, ref}, target_ref) when ref == target_ref, do: true

  defp prototype_chain_contains?({:obj, ref}, target_ref) do
    prototype_chain_contains?(Map.get(Heap.get_obj(ref, %{}), proto()), target_ref)
  end

  defp prototype_chain_contains?(_, _), do: false

  defp object_to_string(nil), do: "[object Null]"
  defp object_to_string(:undefined), do: "[object Undefined]"
  defp object_to_string(value) when is_binary(value), do: "[object String]"
  defp object_to_string(value) when is_number(value), do: "[object Number]"
  defp object_to_string(value) when is_boolean(value), do: "[object Boolean]"
  defp object_to_string({:symbol, _}), do: "[object Symbol]"
  defp object_to_string({:symbol, _, _}), do: "[object Symbol]"
  defp object_to_string({:regexp, _, _}), do: "[object RegExp]"
  defp object_to_string(%Bytecode.Function{}), do: "[object Function]"

  defp object_to_string({tag, _, %Bytecode.Function{}}) when tag in [:closure, :bound],
    do: "[object Function]"

  defp object_to_string({:builtin, _, _}), do: "[object Function]"

  defp object_to_string({:obj, ref} = obj) do
    tag =
      case Heap.get_obj(ref, %{}) do
        list when is_list(list) -> "Array"
        {:qb_arr, _} -> "Array"
        %{"__wrapped_string__" => _} -> "String"
        %{"__wrapped_number__" => _} -> "Number"
        %{"__wrapped_boolean__" => _} -> "Boolean"
        %{map_data() => _, :weak => true} -> "WeakMap"
        %{map_data() => _} -> "Map"
        %{set_data() => _, :weak => true} -> "WeakSet"
        %{set_data() => _} -> "Set"
        %{date_ms() => _} -> "Date"
        _ -> "Object"
      end

    custom_tag = Get.get(obj, {:symbol, "Symbol.toStringTag"})
    "[object #{if is_binary(custom_tag), do: custom_tag, else: tag}]"
  end

  defp object_to_string(_value), do: "[object Object]"

  static "keys" do
    keys(args)
  end

  static "values" do
    values(args)
  end

  static "entries" do
    entries(args)
  end

  static "assign" do
    assign(args)
  end

  static "freeze" do
    case hd(args) do
      {:obj, _ref} = obj ->
        freeze_object(obj)
        obj

      obj ->
        obj
    end
  end

  static "preventExtensions" do
    case hd(args) do
      {:obj, ref} = obj ->
        Heap.prevent_extensions(ref)
        obj

      obj ->
        obj
    end
  end

  static "isExtensible" do
    case hd(args) do
      {:obj, ref} -> Heap.extensible?(ref)
      _ -> false
    end
  end

  static "seal" do
    case hd(args) do
      {:obj, _ref} = obj ->
        seal_object(obj)
        obj

      obj ->
        obj
    end
  end

  static "isFrozen" do
    case hd(args) do
      {:obj, _ref} = obj -> frozen_object?(obj)
      _ -> true
    end
  end

  static "isSealed" do
    case hd(args) do
      {:obj, _ref} = obj -> sealed_object?(obj)
      _ -> true
    end
  end

  defp freeze_object({:obj, ref} = obj) do
    seal_object(obj)

    for key <- own_property_descriptor_keys(obj) do
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

  defp seal_object({:obj, ref} = obj) do
    for key <- own_property_descriptor_keys(obj) do
      desc =
        Heap.get_prop_desc(ref, key) || %{writable: true, enumerable: true, configurable: true}

      Heap.put_prop_desc(ref, key, Map.put(desc, :configurable, false))
    end

    Heap.prevent_extensions(ref)
  end

  defp frozen_object?({:obj, ref} = obj) do
    not Heap.extensible?(ref) and
      Enum.all?(own_property_descriptor_keys(obj), fn key ->
        desc = Heap.get_prop_desc(ref, key) || %{writable: true, configurable: true}
        current = Heap.get_obj(ref, %{}) |> property_value_for_descriptor(key)

        if match?({:accessor, _, _}, current) do
          desc.configurable == false
        else
          desc.configurable == false and desc.writable == false
        end
      end)
  end

  defp sealed_object?({:obj, ref} = obj) do
    not Heap.extensible?(ref) and
      Enum.all?(own_property_descriptor_keys(obj), fn key ->
        desc = Heap.get_prop_desc(ref, key) || %{configurable: true}
        desc.configurable == false
      end)
  end

  defp property_value_for_descriptor(map, key) when is_map(map), do: Map.get(map, key)
  defp property_value_for_descriptor(_data, _key), do: :undefined

  static "is" do
    [a, b | _] = args

    cond do
      is_number(a) and is_number(b) and a == 0 and b == 0 ->
        Values.neg_zero?(a) == Values.neg_zero?(b)

      is_number(a) and is_number(b) ->
        a === b

      a == :nan and b == :nan ->
        true

      true ->
        a === b
    end
  end

  static "create" do
    case args do
      [nil | rest] ->
        create_with_properties(nil, rest)

      [{:obj, _} = proto_value | rest] ->
        create_with_properties(proto_value, rest)

      [_invalid_proto | _] ->
        throw(
          {:js_throw,
           Heap.make_error("Object prototype may only be an Object or null", "TypeError")}
        )

      _ ->
        Runtime.new_object()
    end
  end

  defp create_with_properties(proto_value, rest) do
    obj = Heap.wrap(%{proto() => proto_value})

    case rest do
      [{:obj, _} = props | _] -> define_properties([obj, props])
      _ -> obj
    end
  end

  defp own_property?({:obj, ref}, key), do: own_property?(Heap.get_obj(ref, %{}), key)

  defp own_property?(map, key) when is_map(map) do
    raw_key = parse_array_index_key(key)
    Map.has_key?(map, key) or (raw_key != :error and Map.has_key?(map, raw_key))
  end

  defp own_property?(list, key) when is_list(list) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 -> idx < length(list)
      _ -> key == "length"
    end
  end

  defp own_property?({:qb_arr, arr}, key) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 -> idx < :array.size(arr)
      _ -> key == "length"
    end
  end

  defp own_property?(string, key) when is_binary(string) do
    case Integer.parse(to_string(key)) do
      {idx, ""} when idx >= 0 -> idx < Get.string_length(string)
      _ -> key == "length"
    end
  end

  defp own_property?(_target, _key), do: false

  defp enumerable_property?({:obj, ref}, key),
    do: not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))

  defp enumerable_property?(string, key) when is_binary(string), do: key != "length"
  defp enumerable_property?(_target, _key), do: true

  static "getPrototypeOf" do
    case args do
      [{:obj, ref} | _] ->
        case Heap.get_obj(ref, %{}) do
          %{proxy_target() => target, proxy_handler() => handler} ->
            proxy_get_prototype_of(target, handler)

          map ->
            Map.get(map, proto(), nil)
        end

      [{:qb_arr, _} | _] ->
        func_proto()

      [val | _] when is_list(val) ->
        Runtime.global_class_proto("Array")

      [{:builtin, _, _} = b | _] ->
        case Map.get(Heap.get_ctor_statics(b), "__proto__") do
          nil -> func_proto()
          parent -> parent
        end

      [{:closure, _, _} = c | _] ->
        case Map.get(Heap.get_ctor_statics(c), "__proto__") do
          nil -> func_proto()
          parent -> parent
        end

      [%Bytecode.Function{} | _] ->
        func_proto()

      [val | _] when is_function(val) ->
        func_proto()

      [val | _] when is_integer(val) or is_float(val) ->
        Runtime.global_class_proto("Number")

      [val | _] when is_binary(val) ->
        Runtime.global_class_proto("String")

      [val | _] when is_boolean(val) ->
        Runtime.global_class_proto("Boolean")

      _ ->
        throw(
          {:js_throw, Heap.make_error("Object.getPrototypeOf called on non-object", "TypeError")}
        )
    end
  end

  defp proxy_get_prototype_of(target, handler) do
    trap = Get.get(handler, "getPrototypeOf")

    result =
      if trap == :undefined or trap == nil do
        get_own_prototype(target)
      else
        Invocation.invoke_callback_or_throw(trap, [target])
      end

    cond do
      not prototype_value?(result) ->
        proxy_prototype_invariant_error()

      not target_extensible_for_prototype?(target) and result != get_own_prototype(target) ->
        proxy_prototype_invariant_error()

      true ->
        result
    end
  end

  defp proxy_set_prototype_of(target, handler, new_proto) do
    trap = Get.get(handler, "setPrototypeOf")

    success? =
      if trap == :undefined or trap == nil do
        set_own_prototype(target, new_proto)
        true
      else
        Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target, new_proto]))
      end

    if success? and not target_extensible_for_prototype?(target) and
         new_proto != get_own_prototype(target) do
      proxy_prototype_invariant_error()
    end

    success?
  end

  defp prototype_value?(nil), do: true
  defp prototype_value?({:obj, _}), do: true
  defp prototype_value?(_), do: false

  defp get_own_prototype({:obj, ref}), do: Map.get(Heap.get_obj(ref, %{}), proto(), nil)
  defp get_own_prototype(_), do: nil

  defp set_own_prototype({:obj, ref}, new_proto) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> Heap.put_obj(ref, Map.put(map, proto(), new_proto))
      _ -> :ok
    end
  end

  defp target_extensible_for_prototype?({:obj, ref}), do: Heap.extensible?(ref)
  defp target_extensible_for_prototype?(_), do: true

  defp proxy_prototype_invariant_error do
    throw({:js_throw, Heap.make_error("proxy prototype trap violates invariant", "TypeError")})
  end

  defp func_proto do
    case Heap.get_func_proto() do
      nil ->
        call_fn =
          {:builtin, "call",
           fn [this | args], _ ->
             Runtime.call_callback(this, args)
           end}

        apply_fn =
          {:builtin, "apply",
           fn [this, arg_array], _ ->
             args =
               case arg_array do
                 {:obj, r} -> Heap.obj_to_list(r)
                 _ -> []
               end

             Runtime.call_callback(this, args)
           end}

        bind_fn =
          {:builtin, "bind",
           fn [this | bound_args], func ->
             {:bound, "bound", func, this, bound_args}
           end}

        proto =
          object do
            prop("call", call_fn)
            prop("apply", apply_fn)
            prop("bind", bind_fn)
            prop("constructor", :undefined)
          end

        Heap.put_func_proto(proto)
        proto

      existing ->
        existing
    end
  end

  static "defineProperty" do
    define_property(args)
  end

  static "defineProperties" do
    define_properties(args)
  end

  static "getOwnPropertyNames" do
    get_own_property_names(args)
  end

  static "getOwnPropertyDescriptor" do
    get_own_property_descriptor(args)
  end

  static "getOwnPropertyDescriptors" do
    get_own_property_descriptors(args)
  end

  static "fromEntries" do
    from_entries(args)
  end

  static "getOwnPropertySymbols" do
    case args do
      [{:obj, ref} | _] ->
        data = Heap.get_obj(ref, %{})

        syms =
          if is_map(data), do: Enum.filter(Map.keys(data), &is_symbol/1), else: []

        Heap.wrap(syms)

      _ ->
        Heap.wrap([])
    end
  end

  static "hasOwn" do
    case args do
      [target, _key | _] when target in [nil, :undefined] ->
        throw(
          {:js_throw, Heap.make_error("Object.hasOwn called on null or undefined", "TypeError")}
        )

      [target, key | _] ->
        prop_name = if is_binary(key) or is_symbol(key), do: key, else: Values.stringify(key)
        own_property?(target, prop_name)

      _ ->
        false
    end
  end

  static "setPrototypeOf" do
    case args do
      [_obj, new_proto | _] ->
        unless prototype_value?(new_proto) do
          throw(
            {:js_throw,
             Heap.make_error("Object prototype may only be an object or null", "TypeError")}
          )
        end

        set_prototype_of(args)
    end
  end

  defp set_prototype_of(args) do
    case args do
      [{:obj, ref} = obj, new_proto | _] ->
        case Heap.get_obj(ref, %{}) do
          %{proxy_target() => target, proxy_handler() => handler} ->
            if proxy_set_prototype_of(target, handler, new_proto) do
              obj
            else
              throw(
                {:js_throw,
                 Heap.make_error("proxy setPrototypeOf trap returned false", "TypeError")}
              )
            end

          map when is_map(map) ->
            Heap.put_obj(ref, Map.put(map, proto(), new_proto))
            obj

          _ ->
            obj
        end

      [obj | _] ->
        obj

      _ ->
        :undefined
    end
  end

  defp from_entries([iterable | _]) do
    entries = entries_from_iterable(iterable)
    result_ref = make_ref()

    map =
      Enum.reduce(entries, %{}, fn entry, acc ->
        [key, value | _] = entry_pair(entry)
        Map.put(acc, Runtime.stringify(key), value)
      end)

    Heap.put_obj(result_ref, map)
    {:obj, result_ref}
  end

  defp from_entries(_), do: Runtime.new_object()

  defp entries_from_iterable({:obj, ref} = iterable) do
    iterator_method = Get.get(iterable, {:symbol, "Symbol.iterator"})

    if iterator_method != :undefined and iterator_method != nil do
      iterator = invoke_with_this(iterator_method, [], iterable)
      collect_iterator_values(iterator, [])
    else
      case Heap.obj_to_list(ref) do
        list when is_list(list) -> list
        _ -> []
      end
    end
  end

  defp entries_from_iterable(_iterable) do
    throw({:js_throw, Heap.make_error("Object.fromEntries requires an iterable", "TypeError")})
  end

  defp collect_iterator_values(iterator, acc) do
    next_fn = Get.get(iterator, "next")
    result = invoke_with_this(next_fn, [], iterator)

    if Get.get(result, "done") == true do
      Enum.reverse(acc)
    else
      value = Get.get(result, "value")
      collect_iterator_values(iterator, [value | acc])
    end
  end

  defp entry_pair({:obj, _} = entry) do
    case Heap.to_list(entry) do
      [_, _ | _] = pair ->
        pair

      _ ->
        throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
    end
  end

  defp entry_pair([_, _ | _] = entry), do: entry

  defp entry_pair(_entry) do
    throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
  end

  defp invoke_with_this(fun, args, this) do
    case fun do
      {:builtin, _, callback} when is_function(callback) ->
        callback.(args, this)

      %Bytecode.Function{} = function ->
        Invocation.invoke_with_receiver(function, args, Runtime.gas_budget(), this)

      {:closure, _, %Bytecode.Function{}} = closure ->
        Invocation.invoke_with_receiver(closure, args, Runtime.gas_budget(), this)

      _ ->
        Runtime.call_callback(fun, args)
    end
  end

  defp keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) or match?({:qb_arr, _}, data) do
      Heap.wrap(array_indices(data))
    else
      keys_from_map(ref, data)
    end
  end

  defp keys(_) do
    Heap.wrap([])
  end

  defp keys_from_map(_ref, {:qb_arr, arr}) do
    for i <- 0..(:array.size(arr) - 1), do: Integer.to_string(i)
  end

  defp keys_from_map(_ref, list) when is_list(list) do
    Heap.wrap(array_indices(list))
  end

  defp keys_from_map(ref, map) when is_map(map) do
    Heap.wrap(enumerable_keys(ref))
  end

  defp get_own_property_names([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    names =
      case data do
        {:qb_arr, arr} ->
          for(i <- 0..(:array.size(arr) - 1), do: Integer.to_string(i)) ++ ["length"]

        list when is_list(list) ->
          array_indices(list) ++ ["length"]

        map when is_map(map) ->
          Map.keys(map)
          |> Enum.filter(&is_binary/1)
          |> Enum.reject(fn k -> String.starts_with?(k, "__") and String.ends_with?(k, "__") end)

        _ ->
          []
      end

    Heap.wrap(names)
  end

  defp get_own_property_names(_) do
    Heap.wrap([])
  end

  defp get_own_property_descriptors([{:obj, _} = obj | _]) do
    ref = make_ref()

    descriptors =
      obj
      |> own_property_descriptor_keys()
      |> Enum.reduce(%{}, fn key, acc ->
        case get_own_property_descriptor([obj, key]) do
          :undefined -> acc
          desc -> Map.put(acc, key, desc)
        end
      end)

    Heap.put_obj(ref, descriptors)
    {:obj, ref}
  end

  defp get_own_property_descriptors(_), do: Heap.wrap(%{})

  defp own_property_descriptor_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "ownKeys")

        if trap == :undefined or trap == nil do
          own_property_descriptor_keys(target)
        else
          trap
          |> Runtime.call_callback([target])
          |> Heap.to_list()
        end

      {:qb_arr, arr} ->
        for(i <- 0..(:array.size(arr) - 1), do: Integer.to_string(i)) ++ ["length"]

      list when is_list(list) ->
        array_indices(list) ++ ["length"]

      map when is_map(map) ->
        map
        |> Map.keys()
        |> Enum.reject(&descriptor_internal_key?/1)

      _ ->
        []
    end
  end

  defp own_property_descriptor_keys(_), do: []

  defp descriptor_internal_key?(key) when key in [proto(), proxy_target(), proxy_handler()],
    do: true

  defp descriptor_internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp descriptor_internal_key?(_), do: false

  defp enumerable_keys(ref) do
    data = Heap.get_obj(ref, %{})

    case data do
      list when is_list(list) ->
        array_indices(list)

      map when is_map(map) ->
        map
        |> enumerable_key_pairs()
        |> Enum.map(fn {key, _raw_key} -> key end)
        |> Runtime.sort_numeric_keys()
        |> Enum.filter(fn key -> enumerable_object_key?(ref, map, key) end)

      _ ->
        []
    end
  end

  defp enumerable_key_pairs(map) do
    raw =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> Map.keys(map)
      end

    Enum.flat_map(raw, fn
      key when is_binary(key) -> [{key, key}]
      key when is_integer(key) and key >= 0 -> [{Integer.to_string(key), key}]
      _ -> []
    end)
  end

  defp enumerable_object_key?(ref, map, key) do
    raw_key = if Map.has_key?(map, key), do: key, else: parse_array_index_key(key)

    is_binary(key) and not String.starts_with?(key, "__") and
      raw_key != :error and Map.has_key?(map, raw_key) and
      not match?(%{enumerable: false}, Heap.get_prop_desc(ref, raw_key))
  end

  defp parse_array_index_key(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> idx
      _ -> :error
    end
  end

  defp enumerable_value(obj, map, key) when is_map(map) do
    raw_key = parse_array_index_key(key)

    cond do
      match?({:accessor, _, _}, Map.get(map, key)) -> Get.get(obj, key)
      Map.has_key?(map, key) -> Map.get(map, key)
      raw_key != :error and match?({:accessor, _, _}, Map.get(map, raw_key)) -> Get.get(obj, key)
      raw_key != :error and Map.has_key?(map, raw_key) -> Map.get(map, raw_key)
      true -> Get.get(obj, key)
    end
  end

  defp enumerable_value(obj, _data, key), do: Get.get(obj, key)

  defp values([{:obj, ref} = obj | _]) do
    data = Heap.get_obj(ref, %{})
    Heap.wrap(Enum.map(enumerable_keys(ref), fn key -> enumerable_value(obj, data, key) end))
  end

  defp values([map | _]) when is_map(map), do: Map.values(map)
  defp values(_), do: []

  defp entries([{:obj, ref} = obj | _]) do
    data = Heap.get_obj(ref, %{})

    pairs =
      Enum.map(enumerable_keys(ref), fn key ->
        Heap.wrap([key, enumerable_value(obj, data, key)])
      end)

    Heap.wrap(pairs)
  end

  defp entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end

  defp entries(_), do: []

  defp assign([target | sources]) do
    Enum.reduce(sources, target, fn
      {:obj, ref}, {:obj, _} = target_obj ->
        ref
        |> enumerable_assign_entries()
        |> Enum.each(fn {key, value} -> Put.put(target_obj, key, value) end)

        target_obj

      map, {:obj, _} = target_obj when is_map(map) ->
        map
        |> Enum.reject(fn {key, _value} -> assign_internal_key?(key) end)
        |> Enum.each(fn {key, value} -> Put.put(target_obj, key, value) end)

        target_obj

      _, acc ->
        acc
    end)
  end

  defp enumerable_assign_entries(ref) do
    data = Heap.get_obj(ref, %{})

    enumerable_keys(ref)
    |> Enum.map(fn key -> {key, enumerable_value({:obj, ref}, data, key)} end)
  end

  defp assign_internal_key?(key) when key in [proto(), map_data(), set_data(), typed_array()],
    do: true

  defp assign_internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp assign_internal_key?(_), do: false

  defp non_extensible_new_property?(ref, existing, prop_name) do
    not Heap.extensible?(ref) and not property_present?(existing, prop_name)
  end

  defp property_present?(map, prop_name) when is_map(map) do
    raw_key = parse_array_index_key(prop_name)
    Map.has_key?(map, prop_name) or (raw_key != :error and Map.has_key?(map, raw_key))
  end

  defp property_present?(list, prop_name) when is_list(list) do
    case Integer.parse(prop_name) do
      {idx, ""} when idx >= 0 -> idx < length(list)
      _ -> false
    end
  end

  defp property_present?({:qb_arr, arr}, prop_name) do
    case Integer.parse(prop_name) do
      {idx, ""} when idx >= 0 -> idx < :array.size(arr)
      _ -> false
    end
  end

  defp property_present?(_existing, _prop_name), do: false

  defp incompatible_existing_descriptor?(ref, existing, prop_name, desc) when is_map(existing) do
    current_desc = Heap.get_prop_desc(ref, prop_name)
    current_value = Map.get(existing, prop_name, :undefined)

    cond do
      current_desc == nil ->
        false

      current_desc.configurable == false and Map.get(desc, "configurable") == true ->
        true

      current_desc.configurable == false and Map.has_key?(desc, "enumerable") and
          Map.get(desc, "enumerable") != current_desc.enumerable ->
        true

      current_desc.configurable == false and
          accessor_data_descriptor_conflict?(current_value, desc) ->
        true

      current_desc.configurable == false and accessor_descriptor_conflict?(current_value, desc) ->
        true

      current_desc.configurable == false and current_desc.writable == false and
          Map.get(desc, "writable") == true ->
        true

      current_desc.writable == false and Map.has_key?(desc, "value") and
          Map.get(desc, "value") != current_value ->
        true

      true ->
        false
    end
  end

  defp incompatible_existing_descriptor?(_ref, _existing, _prop_name, _desc), do: false

  defp accessor_data_descriptor_conflict?({:accessor, _, _}, desc) do
    Map.has_key?(desc, "value") or Map.has_key?(desc, "writable")
  end

  defp accessor_data_descriptor_conflict?(_data_value, desc) do
    Map.has_key?(desc, "get") or Map.has_key?(desc, "set")
  end

  defp accessor_descriptor_conflict?({:accessor, old_get, old_set}, desc) do
    (Map.has_key?(desc, "get") and Map.get(desc, "get") != old_get) or
      (Map.has_key?(desc, "set") and Map.get(desc, "set") != old_set)
  end

  defp accessor_descriptor_conflict?(_data_value, _desc), do: false

  defp define_proxy_property(proxy, proxy_map, key, prop_name, desc_obj) do
    target = Map.fetch!(proxy_map, proxy_target())
    handler = Map.fetch!(proxy_map, proxy_handler())
    trap = Get.get(handler, "defineProperty")

    cond do
      trap == :undefined or trap == nil ->
        define_property([target, key, desc_obj])
        proxy

      not Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target, prop_name, desc_obj])) ->
        throw(
          {:js_throw, Heap.make_error("proxy defineProperty trap returned false", "TypeError")}
        )

      proxy_define_property_invariant_violation?(target, prop_name) ->
        throw(
          {:js_throw,
           Heap.make_error("proxy defineProperty trap violates invariant", "TypeError")}
        )

      true ->
        proxy
    end
  end

  defp proxy_define_property_invariant_violation?({:obj, target_ref}, prop_name) do
    existing = Heap.get_obj(target_ref, %{})
    non_extensible_new_property?(target_ref, existing, prop_name)
  end

  defp proxy_define_property_invariant_violation?(_target, _prop_name), do: false

  defp define_property([{:obj, ref} = obj, key, {:obj, desc_ref} = desc_obj | _]) do
    desc = Heap.get_obj(desc_ref, %{})

    prop_name =
      case key do
        k when is_binary(k) -> k
        {:symbol, _} -> key
        {:symbol, _, _} -> key
        _ -> Values.stringify(key)
      end

    existing = Heap.get_obj(ref, %{})

    if is_map(existing) and Map.has_key?(existing, proxy_target()) do
      throw({:early_return, define_proxy_property(obj, existing, key, prop_name, desc_obj)})
    end

    if non_extensible_new_property?(ref, existing, prop_name) or
         incompatible_existing_descriptor?(ref, existing, prop_name, desc) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    if is_list(existing) or match?({:qb_arr, _}, existing) do
      case Integer.parse(prop_name) do
        {idx, ""} when idx >= 0 ->
          writable = Map.get(desc, "writable", true)
          enumerable = Map.get(desc, "enumerable", true)
          configurable = Map.get(desc, "configurable", true)

          Heap.put_prop_desc(ref, prop_name, %{
            writable: writable,
            enumerable: enumerable,
            configurable: configurable
          })

          if Map.has_key?(desc, "value") do
            Heap.array_set(ref, idx, Map.get(desc, "value"))
          end

          throw({:early_return, obj})

        _ ->
          :ok
      end
    end

    if is_map(existing) and Map.get(existing, typed_array()) do
      case Integer.parse(prop_name) do
        {idx, ""} when idx >= 0 ->
          val = Map.get(desc, "value")
          if val != nil, do: TypedArray.set_element(obj, idx, val)
          throw({:early_return, obj})

        _ ->
          :ok
      end
    end

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    if getter != nil or setter != nil do
      existing_desc = Map.get(existing, prop_name)

      {old_get, old_set} =
        case existing_desc do
          {:accessor, g, s} -> {g, s}
          _ -> {nil, nil}
        end

      new_get = if getter != nil, do: getter, else: old_get
      new_set = if setter != nil, do: setter, else: old_set
      Heap.put_obj(ref, Map.put(existing, prop_name, {:accessor, new_get, new_set}))
    else
      val = Map.get(desc, "value", Map.get(existing, prop_name, :undefined))
      Heap.put_obj(ref, Map.put(existing, prop_name, val))
    end

    writable = Map.get(desc, "writable", true)
    enumerable = Map.get(desc, "enumerable", true)
    configurable = Map.get(desc, "configurable", true)

    Heap.put_prop_desc(ref, prop_name, %{
      writable: writable,
      enumerable: enumerable,
      configurable: configurable
    })

    obj
  catch
    {:early_return, val} -> val
  end

  defp define_property([{tag, _, %Bytecode.Function{}} = fun, key, {:obj, desc_ref} | _])
       when tag == :closure do
    define_callable_property(fun, key, desc_ref)
  end

  defp define_property([%Bytecode.Function{} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  defp define_property([{:builtin, _, _} = b, key, {:obj, desc_ref} | _]) do
    define_static_property(b, key, desc_ref)
    b
  end

  defp define_property([_target | _]) do
    throw({:js_throw, Heap.make_error("Object.defineProperty called on non-object", "TypeError")})
  end

  defp define_callable_property(fun, key, desc_ref) do
    define_static_property(fun, key, desc_ref)
    fun
  end

  defp define_static_property(target, key, desc_ref) do
    desc = Heap.get_obj(desc_ref, %{})
    prop_key = if is_binary(key), do: key, else: key

    getter = Map.get(desc, "get")
    setter = Map.get(desc, "set")

    if getter != nil or setter != nil do
      Heap.put_ctor_static(target, prop_key, {:accessor, getter, setter})
    else
      val = Map.get(desc, "value", :undefined)
      Heap.put_ctor_static(target, prop_key, val)
    end
  end

  defp define_properties([obj, {:obj, props_ref} | _]) do
    props = Heap.get_obj(props_ref, %{})

    if is_map(props) do
      for {key, desc} <- props, is_binary(key) do
        define_property([obj, key, desc])
      end
    end

    obj
  end

  defp define_properties([obj | _]), do: obj

  defp get_own_property_descriptor([{:obj, ref}, key | _]) do
    prop_name = if is_binary(key), do: key, else: Values.stringify(key)
    data = Heap.get_obj(ref, %{})

    cond do
      is_map(data) and Map.has_key?(data, proxy_target()) ->
        proxy_own_property_descriptor(data, prop_name)

      is_list(data) or match?({:qb_arr, _}, data) ->
        case Integer.parse(prop_name) do
          {idx, ""} when idx >= 0 ->
            val = Heap.array_get(ref, idx)

            if val == :undefined and Heap.get_prop_desc(ref, prop_name) == nil do
              :undefined
            else
              data_desc =
                Heap.get_prop_desc(ref, prop_name) ||
                  %{writable: true, enumerable: true, configurable: true}

              data_descriptor_obj(val, data_desc)
            end

          _ ->
            :undefined
        end

      is_map(data) and Map.get(data, typed_array()) ->
        case Integer.parse(prop_name) do
          {idx, ""} when idx >= 0 ->
            val = TypedArray.get_element({:obj, ref}, idx)

            if val == :undefined do
              :undefined
            else
              immutable = TypedArray.immutable?({:obj, ref})
              desc_ref = make_ref()

              Heap.put_obj(desc_ref, %{
                "value" => val,
                "writable" => not immutable,
                "enumerable" => true,
                "configurable" => not immutable
              })

              {:obj, desc_ref}
            end

          _ ->
            :undefined
        end

      is_map(data) ->
        case Map.get(data, prop_name) do
          nil ->
            :undefined

          {:accessor, getter, setter} ->
            desc = Heap.get_prop_desc(ref, prop_name) || %{enumerable: true, configurable: true}
            desc_ref = make_ref()

            Heap.put_obj(desc_ref, %{
              "get" => getter || :undefined,
              "set" => setter || :undefined,
              "enumerable" => desc.enumerable,
              "configurable" => desc.configurable
            })

            {:obj, desc_ref}

          val ->
            data_desc =
              Heap.get_prop_desc(ref, prop_name) ||
                %{writable: true, enumerable: true, configurable: true}

            data_descriptor_obj(val, data_desc)
        end

      true ->
        :undefined
    end
  end

  defp get_own_property_descriptor([{:builtin, _, _} = b, key | _]) do
    prop_key = if is_binary(key), do: key, else: key
    statics = Heap.get_ctor_statics(b)

    case Map.get(statics, prop_key) do
      {:accessor, getter, setter} ->
        desc_ref = make_ref()

        Heap.put_obj(desc_ref, %{
          "get" => getter || :undefined,
          "set" => setter || :undefined,
          "enumerable" => false,
          "configurable" => true
        })

        {:obj, desc_ref}

      nil ->
        :undefined

      val ->
        data_descriptor_obj(val, %{writable: true, enumerable: true, configurable: true})
    end
  end

  defp get_own_property_descriptor(_), do: :undefined

  defp proxy_own_property_descriptor(proxy_map, prop_name) do
    target = Map.fetch!(proxy_map, proxy_target())
    handler = Map.fetch!(proxy_map, proxy_handler())
    trap = Get.get(handler, "getOwnPropertyDescriptor")

    if trap == :undefined or trap == nil do
      get_own_property_descriptor([target, prop_name])
    else
      result = Invocation.invoke_callback_or_throw(trap, [target, prop_name])
      validate_proxy_descriptor_result(target, prop_name, result)
    end
  end

  defp validate_proxy_descriptor_result(target, prop_name, :undefined) do
    case target_descriptor_flags(target, prop_name) do
      %{configurable: false} ->
        proxy_descriptor_invariant_error()

      _ ->
        :undefined
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

  defp target_descriptor_flags({:obj, ref}, prop_name), do: Heap.get_prop_desc(ref, prop_name)
  defp target_descriptor_flags(_target, _prop_name), do: nil

  defp target_extensible?({:obj, ref}), do: Heap.extensible?(ref)
  defp target_extensible?(_target), do: true

  defp proxy_descriptor_invariant_error do
    throw(
      {:js_throw,
       Heap.make_error("proxy getOwnPropertyDescriptor trap violates invariant", "TypeError")}
    )
  end

  defp data_descriptor_obj(val, desc) do
    desc_ref = make_ref()

    Heap.put_obj(desc_ref, %{
      "value" => val,
      "writable" => desc.writable,
      "enumerable" => desc.enumerable,
      "configurable" => desc.configurable
    })

    {:obj, desc_ref}
  end

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end
end
