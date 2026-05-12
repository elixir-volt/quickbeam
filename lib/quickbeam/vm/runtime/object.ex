defmodule QuickBEAM.VM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1]
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Define, Get, OwnProperty, PropertyDescriptor, PropertyKey, Put}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.String, as: JSString

  @doc "Builds prototype data for object static methods."
  def build_prototype do
    ref = make_ref()

    Heap.put_obj(
      ref,
      object heap: false do
        method "toString" do
          object_to_string(this)
        end

        method "toLocaleString" do
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
          "toLocaleString",
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
    OwnProperty.present?(target, prop_name) or function_descriptor_present?(target, prop_name)
  end

  defp has_own_property(_, _), do: false

  defp function_descriptor_present?(%QuickBEAM.VM.Function{} = target, key),
    do: OwnProperty.descriptor(target, key) != :undefined

  defp function_descriptor_present?({:closure, _, %QuickBEAM.VM.Function{}} = target, key),
    do: OwnProperty.descriptor(target, key) != :undefined

  defp function_descriptor_present?(_, _), do: false

  defp property_enumerable?([_key | _], target) when target in [nil, :undefined] do
    throw(
      {:js_throw,
       Heap.make_error("propertyIsEnumerable called on null or undefined", "TypeError")}
    )
  end

  defp property_enumerable?([key | _], target) do
    prop_name = if is_binary(key) or is_symbol(key), do: key, else: Values.stringify(key)
    OwnProperty.present?(target, prop_name) and OwnProperty.enumerable?(target, prop_name)
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
    prototype =
      case Heap.get_obj(ref, %{}) do
        {:qb_arr, _} -> Heap.get_array_proto(ref)
        data when is_list(data) -> Heap.get_array_proto(ref)
        map when is_map(map) -> Map.get(map, proto())
        _ -> nil
      end

    prototype_chain_contains?(prototype, proto_ref)
  end

  defp prototype_of?([{:builtin, _, _} | _], {:obj, proto_ref}) do
    case func_proto() do
      {:obj, ^proto_ref} ->
        true

      {:obj, ref} ->
        prototype_chain_contains?(Map.get(Heap.get_obj(ref, %{}), proto()), proto_ref)

      _ ->
        false
    end
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
  defp object_to_string(%QuickBEAM.VM.Function{}), do: "[object Function]"

  defp object_to_string({tag, _, %QuickBEAM.VM.Function{}}) when tag in [:closure, :bound],
    do: "[object Function]"

  defp object_to_string({:builtin, name, map} = obj) when is_map(map) do
    custom_tag = Get.get(obj, {:symbol, "Symbol.toStringTag"})
    "[object #{if is_binary(custom_tag), do: custom_tag, else: name}]"
  end

  defp object_to_string({:builtin, _, _}), do: "[object Function]"

  defp object_to_string({:obj, ref} = obj) do
    tag =
      case Heap.get_obj(ref, %{}) do
        list when is_list(list) ->
          if Heap.get_array_prop(ref, "__arguments__") == true, do: "Arguments", else: "Array"

        {:qb_arr, _} ->
          if Heap.get_array_prop(ref, "__arguments__") == true, do: "Arguments", else: "Array"

        %{"__wrapped_string__" => _} ->
          "String"

        %{"__wrapped_number__" => _} ->
          "Number"

        %{"__wrapped_boolean__" => _} ->
          "Boolean"

        %{map_data() => _, :weak => true} ->
          "WeakMap"

        %{map_data() => _} ->
          "Map"

        %{set_data() => _, :weak => true} ->
          "WeakSet"

        %{set_data() => _} ->
          "Set"

        %{date_ms() => _} ->
          "Date"

        _ ->
          "Object"
      end

    custom_tag = Get.get(obj, {:symbol, "Symbol.toStringTag"})
    "[object #{if is_binary(custom_tag), do: custom_tag, else: tag}]"
  end

  defp object_to_string(_value), do: "[object Object]"

  static "keys", length: 1 do
    keys(args)
  end

  static "values", length: 1 do
    values(args)
  end

  static "entries", length: 1 do
    entries(args)
  end

  static "assign", length: 2, constructable: false do
    assign(args)
  end

  static "freeze", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj ->
        freeze_object(obj)
        obj

      callable when is_tuple(callable) or is_struct(callable) ->
        freeze_callable(callable)
        callable

      obj ->
        obj
    end
  end

  static "preventExtensions", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj ->
        if prevent_extensions_object(obj) do
          obj
        else
          throw({:js_throw, Heap.make_error("Cannot prevent extensions", "TypeError")})
        end

      obj ->
        obj
    end
  end

  static "isExtensible", length: 1 do
    case hd(args) do
      {:obj, ref} -> Heap.extensible?(ref)
      value -> QuickBEAM.VM.Builtin.callable?(value)
    end
  end

  static "seal", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj ->
        seal_object(obj)
        obj

      obj ->
        obj
    end
  end

  static "isFrozen", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj -> frozen_object?(obj)
      _ -> true
    end
  end

  static "isSealed", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj -> sealed_object?(obj)
      _ -> true
    end
  end

  defp freeze_callable(callable) do
    for key <- OwnProperty.descriptor_keys(callable) do
      case OwnProperty.descriptor(callable, key) do
        :undefined ->
          :ok

        desc ->
          current =
            Heap.get_ctor_prop_desc(callable, key) ||
              %{writable: true, enumerable: true, configurable: true}

          attrs =
            if Get.get(desc, "writable") == :undefined do
              Map.put(current, :configurable, false)
            else
              %{current | writable: false, configurable: false}
            end

          Heap.put_ctor_prop_desc(callable, key, attrs)
      end
    end
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
      case OwnProperty.descriptor(obj, key) do
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

          Define.property(obj, key, Heap.wrap(raw_desc), raw_desc)
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

  defp prevent_extensions_object({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "preventExtensions")

        cond do
          trap == :undefined or trap == nil ->
            prevent_extensions_object(target)

          not Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target])) ->
            false

          Heap.extensible?(target) ->
            throw(
              {:js_throw,
               Heap.make_error("proxy preventExtensions trap violates invariant", "TypeError")}
            )

          true ->
            true
        end

      _ ->
        Heap.prevent_extensions(ref)
        true
    end
  end

  defp seal_object({:obj, ref} = obj) do
    for key <- OwnProperty.descriptor_keys(obj) do
      desc =
        Heap.get_prop_desc(ref, key) || %{writable: true, enumerable: true, configurable: true}

      Heap.put_prop_desc(ref, key, Map.put(desc, :configurable, false))
    end

    prevent_extensions_object(obj)
  end

  defp frozen_object?({:obj, ref} = obj) do
    not Heap.extensible?(ref) and
      Enum.all?(OwnProperty.descriptor_keys(obj), fn key ->
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
      Enum.all?(OwnProperty.descriptor_keys(obj), fn key ->
        desc = Heap.get_prop_desc(ref, key) || %{configurable: true}
        desc.configurable == false
      end)
  end

  defp property_value_for_descriptor(map, key) when is_map(map), do: Map.get(map, key)
  defp property_value_for_descriptor(_data, _key), do: :undefined

  static "is", length: 2 do
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

  static "create", length: 2, constructable: false do
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
      [] -> obj
      [:undefined | _] -> obj
      [props | _] -> define_properties([obj, props])
    end
  end

  static "getPrototypeOf", length: 1 do
    case args do
      [{:obj, ref} | _] ->
        case Heap.get_obj(ref, %{}) do
          %{proxy_target() => target, proxy_handler() => handler} ->
            proxy_get_prototype_of(target, handler)

          map when is_map(map) ->
            get_own_prototype({:obj, ref})

          {:qb_arr, _} ->
            Heap.get_array_proto(ref)

          list when is_list(list) ->
            Heap.get_array_proto(ref)

          _ ->
            nil
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

      [%QuickBEAM.VM.Function{} | _] ->
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

  defp get_own_prototype({:obj, ref}) do
    map = Heap.get_obj(ref, %{})

    cond do
      Map.has_key?(map, :__internal_proto__) -> Map.get(map, :__internal_proto__)
      Heap.get_prop_desc(ref, proto()) -> Heap.get_object_prototype()
      true -> Map.get(map, proto(), nil)
    end
  end

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

  static "defineProperty", length: 3, constructable: false do
    define_property(args)
  end

  static "defineProperties", length: 2, constructable: false do
    define_properties(args)
  end

  static "getOwnPropertyNames", length: 1 do
    get_own_property_names(args)
  end

  static "getOwnPropertyDescriptor", length: 2 do
    get_own_property_descriptor(args)
  end

  static "getOwnPropertyDescriptors", length: 1 do
    get_own_property_descriptors(args)
  end

  static "fromEntries", length: 1 do
    from_entries(args)
  end

  static "getOwnPropertySymbols", length: 1 do
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

  static "hasOwn", length: 2 do
    case args do
      [target, _key | _] when target in [nil, :undefined] ->
        throw(
          {:js_throw, Heap.make_error("Object.hasOwn called on null or undefined", "TypeError")}
        )

      [target, key | _] ->
        prop_name = if is_binary(key) or is_symbol(key), do: key, else: Values.stringify(key)
        OwnProperty.present?(target, prop_name)

      _ ->
        false
    end
  end

  static "setPrototypeOf", length: 2 do
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
    source_entries = entries_from_iterable(iterable)

    result =
      case QuickBEAM.VM.Runtime.Constructors.class_proto("Object") do
        {:obj, _} = proto ->
          ref = make_ref()
          Heap.put_obj(ref, %{proto() => proto, key_order() => []})
          {:obj, ref}

        _ ->
          Runtime.new_object()
      end

    {:obj, result_ref} = result

    order = add_from_entries(source_entries, result_ref, [])

    Heap.put_obj_key(result_ref, key_order(), order)

    result
  end

  defp from_entries(_) do
    throw({:js_throw, Heap.make_error("Object.fromEntries requires an iterable", "TypeError")})
  end

  defp from_entries_property_key({:obj, _} = key) do
    case Get.get(key, {:symbol, "Symbol.toPrimitive"}) do
      primitive_fn when primitive_fn not in [nil, :undefined] ->
        primitive =
          Invocation.invoke_with_receiver(primitive_fn, ["string"], Runtime.gas_budget(), key)

        PropertyKey.normalize(primitive)

      _ ->
        PropertyKey.normalize(key)
    end
  end

  defp from_entries_property_key(key), do: PropertyKey.normalize(key)

  defp entries_from_iterable({:obj, ref} = iterable) do
    iterator_method = Get.get(iterable, {:symbol, "Symbol.iterator"})

    if iterator_method != :undefined and iterator_method != nil do
      iterator = invoke_with_this(iterator_method, [], iterable)
      {:iterator, iterator}
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

  defp add_from_entries({:iterator, iterator}, result_ref, order) do
    next_fn = Get.get(iterator, "next")

    unless QuickBEAM.VM.Builtin.callable?(next_fn) do
      throw({:js_throw, Heap.make_error("Iterator next is not callable", "TypeError")})
    end

    result = invoke_with_this(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      throw({:js_throw, Heap.make_error("Iterator result is not an object", "TypeError")})
    end

    if Get.get(result, "done") == true do
      order
    else
      entry = Get.get(result, "value")

      try do
        [key, value | _] = entry_pair(entry)
        prop_key = from_entries_property_key(key)
        Heap.put_obj_key(result_ref, prop_key, value)

        next_order =
          if is_binary(prop_key) and prop_key not in order, do: [prop_key | order], else: order

        add_from_entries({:iterator, iterator}, result_ref, next_order)
      catch
        {:js_throw, _} = thrown ->
          close_iterator(iterator)
          throw(thrown)
      end
    end
  end

  defp add_from_entries(entries, result_ref, order) when is_list(entries) do
    Enum.reduce(entries, order, fn entry, acc ->
      [key, value | _] = entry_pair(entry)
      prop_key = from_entries_property_key(key)
      Heap.put_obj_key(result_ref, prop_key, value)

      if is_binary(prop_key) and prop_key not in acc, do: [prop_key | acc], else: acc
    end)
  end

  defp close_iterator(iterator) do
    case Get.get(iterator, "return") do
      return_fn when return_fn not in [nil, :undefined] ->
        invoke_with_this(return_fn, [], iterator)

      _ ->
        :undefined
    end
  end

  defp entry_pair([_, _ | _] = entry), do: entry

  defp entry_pair({:obj, _} = entry) do
    case Heap.to_list(entry) do
      [_, _ | _] = pair ->
        pair

      _ ->
        case Heap.get_obj(entry, %{}) do
          %{"__wrapped_string__" => <<key::utf8, value::utf8, _::binary>>} ->
            [<<key::utf8>>, <<value::utf8>>]

          _ ->
            entry_pair_from_properties(entry)
        end
    end
  end

  defp entry_pair(_entry) do
    throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
  end

  defp entry_pair_from_properties(entry) do
    key = Get.get(entry, "0")

    if key == :undefined do
      throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
    end

    value = Get.get(entry, "1")

    if value == :undefined do
      _ = from_entries_property_key(key)
      throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
    end

    [key, value]
  end

  defp invoke_with_this(fun, args, this) do
    case fun do
      {:builtin, _, callback} when is_function(callback) ->
        callback.(args, this)

      %QuickBEAM.VM.Function{} = function ->
        Invocation.invoke_with_receiver(function, args, Runtime.gas_budget(), this)

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        Invocation.invoke_with_receiver(closure, args, Runtime.gas_budget(), this)

      _ ->
        Runtime.call_callback(fun, args)
    end
  end

  defp keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) or match?({:qb_arr, _}, data) do
      Heap.wrap(enumerable_keys(ref))
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
          OwnProperty.descriptor_keys({:obj, ref})

        _ ->
          []
      end

    Heap.wrap(names)
  end

  defp get_own_property_names([target | _])
       when is_tuple(target) or is_struct(target) do
    Heap.wrap(OwnProperty.descriptor_keys(target))
  end

  defp get_own_property_names(_) do
    Heap.wrap([])
  end

  defp get_own_property_descriptors([{:obj, _} = obj | _]) do
    ref = make_ref()

    descriptors =
      obj
      |> OwnProperty.descriptor_keys()
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

  defp enumerable_keys(ref) do
    data = Heap.get_obj(ref, %{})

    case data do
      {:qb_arr, arr} ->
        (array_prop_keys(ref) ++
           (arr
            |> :array.sparse_to_orddict()
            |> Enum.map(fn {index, _value} -> Integer.to_string(index) end)
            |> Enum.reject(fn key ->
              match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
            end)))
        |> Runtime.sort_numeric_keys()

      list when is_list(list) ->
        (array_indices(list) ++ array_prop_keys(ref)) |> Runtime.sort_numeric_keys()

      map when is_map(map) and is_map_key(map, proxy_target()) ->
        {:obj, ref}
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(&proxy_enumerable_key?({:obj, ref}, &1))

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

  defp proxy_enumerable_key?(obj, key) do
    case OwnProperty.descriptor(obj, key) do
      :undefined -> false
      {:obj, desc_ref} -> Values.truthy?(Get.get({:obj, desc_ref}, "enumerable"))
      _ -> false
    end
  end

  defp array_prop_keys(ref) do
    ref
    |> Heap.get_array_props()
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_binary(key) and not (String.starts_with?(key, "__") and String.ends_with?(key, "__")) and
        not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
    end)
  end

  defp enumerable_key_pairs(map) do
    raw =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> []
      end

    raw = raw ++ (Map.keys(map) -- raw)

    Enum.flat_map(raw, fn
      key when is_binary(key) -> [{key, key}]
      key when is_integer(key) and key >= 0 -> [{Integer.to_string(key), key}]
      _ -> []
    end)
  end

  defp enumerable_object_key?(ref, map, key) do
    raw_key = if Map.has_key?(map, key), do: key, else: parse_array_index_key(key)

    raw_key = if raw_key != :error and Map.has_key?(map, raw_key), do: raw_key, else: key

    is_binary(key) and not String.starts_with?(key, "__") and Map.has_key?(map, raw_key) and
      not match?(%{enumerable: false}, Heap.get_prop_desc(ref, raw_key))
  end

  defp parse_array_index_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> idx
      _ -> :error
    end
  end

  defp parse_array_index_key(_key), do: :error

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

  defp entries([target | _]) when target in [nil, :undefined] do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp entries([{:obj, _ref} = obj | _]) do
    pairs =
      obj
      |> OwnProperty.descriptor_keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.reduce([], fn key, acc ->
        case OwnProperty.descriptor(obj, key) do
          :undefined ->
            acc

          desc ->
            if Get.get(desc, "enumerable") == true do
              [Heap.wrap([key, Get.get(obj, key)]) | acc]
            else
              acc
            end
        end
      end)
      |> Enum.reverse()

    Heap.wrap(pairs)
  end

  defp entries([callable | _]) when is_tuple(callable) or is_struct(callable) do
    pairs =
      callable
      |> OwnProperty.descriptor_keys()
      |> Enum.reduce([], fn key, acc ->
        case OwnProperty.descriptor(callable, key) do
          :undefined ->
            acc

          desc ->
            if Get.get(desc, "enumerable") == true do
              [Heap.wrap([key, Get.get(callable, key)]) | acc]
            else
              acc
            end
        end
      end)
      |> Enum.reverse()

    Heap.wrap(pairs)
  end

  defp entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end

  defp entries([string | _]) when is_binary(string) do
    string
    |> string_indexed_entries()
    |> Enum.map(fn {index, char} -> Heap.wrap([index, char]) end)
    |> Heap.wrap()
  end

  defp entries(_), do: []

  defp assign([target | _sources]) when target in [nil, :undefined] do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp assign([target | sources]) do
    target_obj = to_assign_target(target)

    Enum.reduce(sources, target_obj, fn
      source, target_obj when source in [nil, :undefined] ->
        target_obj

      {:obj, ref}, {:obj, _} = target_obj ->
        ref
        |> enumerable_assign_entries()
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      source, {:obj, _} = target_obj when is_binary(source) ->
        source
        |> string_assign_entries()
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      map, {:obj, _} = target_obj when is_map(map) ->
        map
        |> Enum.reject(fn {key, _value} -> assign_internal_key?(key) end)
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      _, acc ->
        acc
    end)
  end

  defp assign_put({:obj, ref} = target_obj, key, value) do
    cond do
      target_accessor_setter?(ref, key) ->
        Put.put(target_obj, key, value)

      target_readonly?(ref, key) or target_string_index?(ref, key) ->
        throw({:js_throw, Heap.make_error("Cannot assign to read only property", "TypeError")})

      not target_has_own?(ref, key) and not Heap.extensible?(ref) ->
        throw({:js_throw, Heap.make_error("Cannot add property", "TypeError")})

      true ->
        Put.put(target_obj, key, value)
    end
  end

  defp target_accessor_setter?(ref, key) do
    case target_own_value(ref, key) do
      {:accessor, _, setter} when setter != nil -> true
      _ -> false
    end
  end

  defp target_readonly?(ref, key), do: match?(%{writable: false}, Heap.get_prop_desc(ref, key))

  defp target_string_index?(ref, key) do
    case Heap.get_obj_raw(ref) do
      map when is_map(map) and is_binary(key) ->
        case {Map.get(map, "__wrapped_string__"), Integer.parse(key)} do
          {string, {index, ""}} when is_binary(string) and index >= 0 ->
            index < Get.string_length(string)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp target_has_own?(ref, key), do: target_own_value(ref, key) != :missing

  defp target_own_value(ref, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, vals, _proto} ->
        case Map.fetch(offsets, key) do
          {:ok, offset} -> elem(vals, offset)
          :error -> :missing
        end

      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, value} -> value
          :error -> :missing
        end

      _ ->
        :missing
    end
  end

  defp to_assign_target({:obj, _} = object), do: object
  defp to_assign_target(target), do: object_value_of(target)

  defp string_assign_entries(string), do: string_indexed_entries(string)

  defp string_indexed_entries(string), do: JSString.utf16_indexed_entries(string)

  defp enumerable_assign_entries(ref) do
    data = Heap.get_obj(ref, %{})

    if is_map(data) and Map.has_key?(data, proxy_target()) do
      proxy_assign_entries({:obj, ref}, data)
    else
      (enumerable_keys(ref) ++ enumerable_symbol_keys(ref, data))
      |> Enum.map(fn key -> {key, enumerable_value({:obj, ref}, data, key)} end)
    end
  end

  defp proxy_assign_entries(source_obj, %{proxy_target() => target, proxy_handler() => handler}) do
    keys =
      case Get.get(handler, "ownKeys") do
        trap when trap != nil and trap != :undefined ->
          trap |> Runtime.call_callback([target]) |> Heap.to_list()

        _ ->
          enumerable_keys(elem(target, 1))
      end

    descriptor_trap = Get.get(handler, "getOwnPropertyDescriptor")

    keys
    |> Enum.filter(fn key ->
      (is_binary(key) or is_symbol(key)) and
        proxy_assign_enumerable?(target, descriptor_trap, key)
    end)
    |> Enum.map(fn key -> {key, Get.get(source_obj, key)} end)
  end

  defp proxy_assign_enumerable?(target, descriptor_trap, key) do
    descriptor =
      if descriptor_trap != nil and descriptor_trap != :undefined do
        Runtime.call_callback(descriptor_trap, [target, key])
      else
        get_own_property_descriptor([target, key])
      end

    descriptor != :undefined and Get.get(descriptor, "enumerable") == true
  end

  defp enumerable_symbol_keys(ref, data) when is_map(data) do
    data
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_symbol(key) and not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
    end)
  end

  defp enumerable_symbol_keys(_ref, _data), do: []

  defp assign_internal_key?(key) when key in [proto(), map_data(), set_data(), typed_array()],
    do: true

  defp assign_internal_key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  defp assign_internal_key?(_), do: false

  defp define_property([{:obj, _} = obj, key, {:obj, desc_ref} = desc_obj | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    Define.property(obj, key, desc_obj, desc)
  end

  defp define_property([{:obj, _} = obj, key, desc_obj | _])
       when is_tuple(desc_obj) or is_struct(desc_obj) do
    if descriptor_object?(desc_obj) do
      Define.property(obj, key, desc_obj, %{})
    else
      throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
    end
  end

  defp define_property([{tag, _, %QuickBEAM.VM.Function{}} = fun, key, {:obj, desc_ref} | _])
       when tag == :closure do
    define_callable_property(fun, key, desc_ref)
  end

  defp define_property([%QuickBEAM.VM.Function{} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  defp define_property([{:builtin, _, _} = b, key, {:obj, desc_ref} | _]) do
    define_static_property(b, key, desc_ref)
    b
  end

  defp define_property([_target | _]) do
    throw({:js_throw, Heap.make_error("Object.defineProperty called on non-object", "TypeError")})
  end

  defp descriptor_object?({:builtin, _, _}), do: true
  defp descriptor_object?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp descriptor_object?(%QuickBEAM.VM.Function{}), do: true
  defp descriptor_object?(_), do: false

  defp define_callable_property(fun, key, desc_ref) do
    define_static_property(fun, key, desc_ref)
    fun
  end

  defp callable_own_keys(callable) do
    callable
    |> Heap.get_ctor_statics()
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(fn key -> String.starts_with?(key, "__") and String.ends_with?(key, "__") end)
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

  defp define_properties([target, _props | _]) when target in [nil, :undefined] do
    throw(
      {:js_throw, Heap.make_error("Object.defineProperties called on non-object", "TypeError")}
    )
  end

  defp define_properties([target, _props | _])
       when not is_tuple(target) and not is_struct(target) do
    throw(
      {:js_throw, Heap.make_error("Object.defineProperties called on non-object", "TypeError")}
    )
  end

  defp define_properties([obj, {:obj, props_ref} = props | _]) do
    for key <- enumerable_keys(props_ref) do
      define_property([obj, key, Get.get(props, key)])
    end

    obj
  end

  defp define_properties([obj, props | _]) when is_tuple(props) or is_struct(props) do
    if descriptor_object?(props) do
      for key <- callable_own_keys(props) do
        define_property([obj, key, Get.get(props, key)])
      end

      obj
    else
      obj
    end
  end

  defp define_properties([_obj, props | _]) when props in [nil, :undefined] do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp define_properties([obj, props | _]) when is_binary(props) do
    if props == "" do
      obj
    else
      throw({:js_throw, Heap.make_error("Property description must be an object", "TypeError")})
    end
  end

  defp define_properties([obj | _]), do: obj

  defp get_own_property_descriptor([target, _key | _]) when target in [nil, :undefined] do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp get_own_property_descriptor([target, key | _]) do
    OwnProperty.descriptor(target, key)
  end

  defp get_own_property_descriptor(_), do: :undefined

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end
end
