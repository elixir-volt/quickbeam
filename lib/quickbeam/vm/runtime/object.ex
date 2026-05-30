defmodule QuickBEAM.VM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1, is_nullish: 1]
  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Semantics.{Iterators, Values}
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Get,
    InternalMethods,
    OwnProperty,
    PropertyKey,
    Prototype,
    Semantics,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.ObjectAssign
  alias QuickBEAM.VM.Runtime.ObjectDescriptors
  alias QuickBEAM.VM.Runtime.ObjectEnumeration
  alias QuickBEAM.VM.Runtime.ObjectIntegrity
  alias QuickBEAM.VM.Runtime.ConstructorRegistry, as: ConstructorRegistry

  @ecma "20.1"
  defintrinsic "Object", prototype_parent: nil do
    constructor(&QuickBEAM.VM.Runtime.ConstructorCallbacks.object/2,
      length: 1,
      phase: :core
    )

    install_with(&__MODULE__.install_builtin/2)
  end

  def install_builtin(ctor, opts \\ []) do
    obj_proto =
      Keyword.get_lazy(opts, :prototype, fn ->
        case Heap.get_object_prototype() do
          nil -> build_prototype()
          existing -> existing
        end
      end)

    ConstructorRegistry.put_prototype(ctor, obj_proto)

    case obj_proto do
      {:obj, proto_ref} ->
        case Heap.get_obj(proto_ref, %{}) do
          map when is_map(map) -> Heap.put_obj(proto_ref, Map.put(map, "constructor", ctor))
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  def realm_constructor(
        object_proto,
        boolean_proto,
        number_proto,
        bigint_proto,
        string_proto,
        symbol_proto
      ) do
    fn
      [value | _], _this ->
        object_value(
          value,
          object_proto,
          boolean_proto,
          number_proto,
          bigint_proto,
          string_proto,
          symbol_proto
        )

      [], {:obj, _} = this ->
        this

      [], _this ->
        object extends: object_proto do
        end
    end
  end

  defp object_value(
         {:obj, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         _symbol_proto
       ),
       do: value

  defp object_value(
         value,
         _object_proto,
         boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         _symbol_proto
       )
       when is_boolean(value) do
    object extends: boolean_proto do
      prop(slot_key(:BooleanData), value)
    end
  end

  defp object_value(
         value,
         _object_proto,
         _boolean_proto,
         number_proto,
         _bigint_proto,
         _string_proto,
         _symbol_proto
       )
       when is_number(value) do
    object extends: number_proto do
      prop(slot_key(:NumberData), value)
    end
  end

  defp object_value(
         {:bigint, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         bigint_proto,
         _string_proto,
         _symbol_proto
       ) do
    object extends: bigint_proto do
      prop(slot_key(:BigIntData), value)
    end
  end

  defp object_value(
         value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         string_proto,
         _symbol_proto
       )
       when is_binary(value) do
    object extends: string_proto do
      prop(slot_key(:StringData), value)
    end
  end

  defp object_value(
         {:symbol, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         symbol_proto
       ) do
    object extends: symbol_proto do
      prop(slot_key(:SymbolData), value)
    end
  end

  defp object_value(
         {:symbol, _, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         symbol_proto
       ) do
    object extends: symbol_proto do
      prop(slot_key(:SymbolData), value)
    end
  end

  defp object_value(
         _value,
         object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         _symbol_proto
       ) do
    object extends: object_proto do
    end
  end

  @doc "Builds prototype data for object static methods."
  def build_prototype do
    ref = make_ref()

    Heap.put_obj(
      ref,
      Map.put(
        object heap: false do
          @ecma "20.1.3.6"
          method "toString" do
            object_to_string(this)
          end

          @ecma "20.1.3.3"
          method "toLocaleString" do
            object_to_locale_string(this)
          end

          @ecma "20.1.3.7"
          method "valueOf" do
            object_value_of(this)
          end

          @ecma "20.1.3.2"
          method "hasOwnProperty" do
            has_own_property(args, this)
          end

          @ecma "20.1.3.4"
          method "isPrototypeOf" do
            prototype_of?(args, this)
          end

          @ecma "20.1.3.5"
          method "propertyIsEnumerable" do
            property_enumerable?(args, this)
          end

          @ecma "20.1.3.9.1"
          method "__defineGetter__", length: 2 do
            define_accessor_property(args, this, :get)
          end

          @ecma "20.1.3.9.2"
          method "__defineSetter__", length: 2 do
            define_accessor_property(args, this, :set)
          end

          @ecma "20.1.3.9.3"
          method "__lookupGetter__", length: 1 do
            lookup_accessor_property(args, this, :get)
          end

          @ecma "20.1.3.9.4"
          method "__lookupSetter__", length: 1 do
            lookup_accessor_property(args, this, :set)
          end

          @ecma "20.1.3.8"
          accessor "__proto__" do
            get do
              object_proto_get(this)
            end

            set do
              object_proto_set(args, this)
            end
          end
        end,
        :__internal_proto__,
        nil
      )
    )

    proto = {:obj, ref}

    for key <- [
          "toString",
          "toLocaleString",
          "valueOf",
          "hasOwnProperty",
          "isPrototypeOf",
          "propertyIsEnumerable",
          "__defineGetter__",
          "__defineSetter__",
          "__lookupGetter__",
          "__lookupSetter__",
          "__proto__",
          "constructor"
        ] do
      Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true, writable: true})
    end

    Heap.put_object_prototype(proto)
    proto
  end

  defp object_proto_get(target) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp object_proto_get(target), do: InternalMethods.get_prototype_of(target)

  defp object_proto_set(_args, target) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp object_proto_set([proto | _], {:obj, ref} = target) do
    if proto == nil or match?({:obj, _}, proto) do
      cond do
        InternalMethods.get_prototype_of(target) == proto ->
          :ok

        target == Heap.get_object_prototype() and proto != nil ->
          throw({:js_throw, Heap.make_error("Cannot set immutable prototype", "TypeError")})

        target == Heap.get_object_prototype() ->
          :ok

        match?({:obj, _}, proto) and Prototype.ordinary_chain_contains?(proto, ref) ->
          throw({:js_throw, Heap.make_error("Cannot create prototype cycle", "TypeError")})

        not Heap.extensible?(ref) and InternalMethods.get_prototype_of(target) != proto ->
          throw(
            {:js_throw,
             Heap.make_error("Cannot set prototype of non-extensible object", "TypeError")}
          )

        true ->
          InternalMethods.set_prototype_of(target, proto)
      end
    end

    :undefined
  end

  defp object_proto_set([proto | _], target) do
    if proto == nil or match?({:obj, _}, proto) do
      InternalMethods.set_prototype_of(target, proto)
    end

    :undefined
  end

  defp object_proto_set(_args, _target), do: :undefined

  defp define_accessor_property(_args, target, _kind) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp define_accessor_property([key, callback | _], target, kind) do
    unless QuickBEAM.VM.Builtin.callable?(callback) do
      throw(
        {:js_throw, Heap.make_error("Object.prototype accessor must be callable", "TypeError")}
      )
    end

    prop_key = PropertyKey.to_property_key(key)

    desc =
      case kind do
        :get -> %{"get" => callback, "enumerable" => true, "configurable" => true}
        :set -> %{"set" => callback, "enumerable" => true, "configurable" => true}
      end

    desc_obj = Heap.wrap(desc)
    InternalMethods.define_own_property(target, prop_key, desc_obj, desc)
    :undefined
  end

  defp define_accessor_property(_args, _target, _kind) do
    throw({:js_throw, Heap.make_error("Object.prototype accessor must be callable", "TypeError")})
  end

  defp lookup_accessor_property(_args, target, _kind) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp lookup_accessor_property([key | _], target, kind) do
    lookup_accessor_in_chain(target, PropertyKey.to_property_key(key), kind)
  end

  defp lookup_accessor_property(_args, _target, _kind), do: :undefined

  defp lookup_accessor_in_chain(nil, _key, _kind), do: :undefined

  defp lookup_accessor_in_chain(obj, key, kind) do
    case InternalMethods.own_property(obj, key) do
      {:obj, _} = desc ->
        getter = Get.get(desc, "get")
        setter = Get.get(desc, "set")

        if getter != :undefined or setter != :undefined do
          case kind do
            :get -> if getter == :undefined, do: :undefined, else: getter
            :set -> if setter == :undefined, do: :undefined, else: setter
          end
        else
          :undefined
        end

      :undefined ->
        lookup_accessor_in_chain(InternalMethods.get_prototype_of(obj), key, kind)
    end
  end

  defp has_own_property([key | _], target) do
    prop_name = PropertyKey.to_property_key(key)

    if Value.nullish?(target) do
      throw(
        {:js_throw, Heap.make_error("hasOwnProperty called on null or undefined", "TypeError")}
      )
    end

    OwnProperty.present?(target, prop_name) or function_descriptor_present?(target, prop_name)
  end

  defp has_own_property(_, _), do: false

  defp function_descriptor_present?(%QuickBEAM.VM.Function{} = target, key),
    do: InternalMethods.own_property(target, key) != :undefined

  defp function_descriptor_present?({:closure, _, %QuickBEAM.VM.Function{}} = target, key),
    do: InternalMethods.own_property(target, key) != :undefined

  defp function_descriptor_present?(_, _), do: false

  defp property_enumerable?([key | _], target) do
    prop_name = PropertyKey.to_property_key(key)

    if Value.nullish?(target) do
      throw(
        {:js_throw,
         Heap.make_error("propertyIsEnumerable called on null or undefined", "TypeError")}
      )
    end

    OwnProperty.present?(target, prop_name) and OwnProperty.enumerable?(target, prop_name)
  end

  defp property_enumerable?(_, _), do: false

  defp object_value_of(value) when is_nullish(value) do
    throw(
      {:js_throw,
       Heap.make_error("Object.prototype.valueOf called on null or undefined", "TypeError")}
    )
  end

  defp object_value_of({:obj, _} = obj), do: obj

  defp object_value_of(value) when is_binary(value), do: WrappedPrimitive.wrap(value)
  defp object_value_of(value) when is_number(value), do: WrappedPrimitive.wrap(value)
  defp object_value_of(value) when is_boolean(value), do: WrappedPrimitive.wrap(value)
  defp object_value_of({:symbol, _, _} = value), do: WrappedPrimitive.wrap(value)
  defp object_value_of({:symbol, _} = value), do: WrappedPrimitive.wrap(value)
  defp object_value_of(value), do: value

  defp prototype_of?([value | _], target) do
    cond do
      not is_object_like?(value) ->
        false

      Value.nullish?(target) ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")}
        )

      match?({:obj, _}, target) ->
        {:obj, proto_ref} = target
        Prototype.chain_contains?(value, proto_ref)

      true ->
        false
    end
  end

  defp prototype_of?(_, _), do: false

  defp object_to_string(nil), do: "[object Null]"
  defp object_to_string(:undefined), do: "[object Undefined]"

  defp object_to_string(value) do
    object_tag(value, builtin_to_string_tag(value))
  end

  defp object_tag(value, fallback) do
    tag = Get.get(value, {:symbol, "Symbol.toStringTag"})
    "[object #{if is_binary(tag), do: tag, else: fallback}]"
  end

  defp builtin_to_string_tag(value) when is_binary(value), do: "String"
  defp builtin_to_string_tag(value) when is_number(value), do: "Number"
  defp builtin_to_string_tag(value) when is_boolean(value), do: "Boolean"
  defp builtin_to_string_tag({:regexp, _, _}), do: "RegExp"
  defp builtin_to_string_tag({:regexp, _, _, _}), do: "RegExp"

  defp builtin_to_string_tag(value) do
    cond do
      QuickBEAM.VM.Builtin.callable?(value) -> "Function"
      true -> object_builtin_to_string_tag(value)
    end
  end

  defp object_builtin_to_string_tag({:obj, ref}) do
    ref
    |> Heap.get_obj(%{})
    |> object_storage_to_string_tag(ref)
  end

  defp object_builtin_to_string_tag(_value), do: "Object"

  defp object_storage_to_string_tag(data, ref) when is_list(data), do: array_or_arguments_tag(ref)
  defp object_storage_to_string_tag({:qb_arr, _}, ref), do: array_or_arguments_tag(ref)

  defp object_storage_to_string_tag(map, _ref) when is_map(map) do
    cond do
      Map.has_key?(map, proxy_target()) -> builtin_to_string_tag(Map.fetch!(map, proxy_target()))
      Semantics.array_prototype_object?(map) -> "Array"
      Map.has_key?(map, date_ms()) -> "Date"
      Map.has_key?(map, "__error_name__") -> "Error"
      true -> wrapped_or_ordinary_object_tag(map)
    end
  end

  defp object_storage_to_string_tag(_data, _ref), do: "Object"

  defp array_or_arguments_tag(ref) do
    if Heap.get_array_prop(ref, "__arguments__") == true, do: "Arguments", else: "Array"
  end

  defp wrapped_or_ordinary_object_tag(map) do
    case WrappedPrimitive.type(map) do
      :string -> "String"
      :number -> "Number"
      :boolean -> "Boolean"
      _ -> "Object"
    end
  end

  defp object_to_locale_string(this) do
    to_string_fn = Get.get(this, "toString")

    unless QuickBEAM.VM.Builtin.callable?(to_string_fn) do
      JSThrow.type_error!("toString is not callable")
    end

    this
    |> then(&QuickBEAM.VM.Invocation.invoke_with_receiver(to_string_fn, [], &1))
    |> Runtime.stringify()
  end

  @ecma "20.1.2.19"
  static "keys", length: 1 do
    ObjectEnumeration.keys(args)
  end

  @ecma "20.1.2.24"
  static "values", length: 1 do
    ObjectEnumeration.values(args)
  end

  @ecma "20.1.2.5"
  static "entries", length: 1 do
    ObjectEnumeration.entries(args)
  end

  @ecma "20.1.2.1"
  static "assign", length: 2, constructable: false do
    ObjectAssign.assign(args)
  end

  @ecma "20.1.2.6"
  static "freeze", length: 1 do
    args |> hd() |> ObjectIntegrity.freeze()
  end

  @ecma "20.1.2.17"
  static "preventExtensions", length: 1 do
    args |> hd() |> ObjectIntegrity.prevent_extensions()
  end

  @ecma "20.1.2.16"
  static "isExtensible", length: 1 do
    args |> hd() |> ObjectIntegrity.extensible?()
  end

  @ecma "20.1.2.22"
  static "seal", length: 1 do
    args |> hd() |> ObjectIntegrity.seal()
  end

  @ecma "20.1.2.17"
  static "isFrozen", length: 1 do
    args |> hd() |> ObjectIntegrity.frozen?()
  end

  @ecma "20.1.2.18"
  static "isSealed", length: 1 do
    args |> hd() |> ObjectIntegrity.sealed?()
  end

  defp is_object_like?(value), do: Value.object_like?(value)

  @ecma "20.1.2.15"
  static "is", length: 2 do
    a = arg(args, 0, :undefined)
    b = arg(args, 1, :undefined)

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

  @ecma "20.1.2.2"
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
    proto_value = if proto_value == nil, do: :null_proto, else: proto_value
    obj = Heap.wrap(%{proto() => proto_value})

    case rest do
      [] -> obj
      [:undefined | _] -> obj
      [props | _] -> ObjectDescriptors.define_properties([obj, props])
    end
  end

  @ecma "20.1.2.12"
  static "getPrototypeOf", length: 1 do
    case args do
      [{:obj, ref} | _] ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> InternalMethods.get_prototype_of({:obj, ref})
          {:qb_arr, _} -> InternalMethods.get_prototype_of({:obj, ref})
          list when is_list(list) -> InternalMethods.get_prototype_of({:obj, ref})
          _ -> nil
        end

      [{:qb_arr, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [value | _] when is_list(value) ->
        InternalMethods.get_prototype_of(value)

      [{:builtin, _, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [{:regexp, _, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [{:regexp, _, _, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [{:closure, _, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [{:bound, _, _, _, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [%QuickBEAM.VM.Function{} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [value | _] when is_function(value) ->
        InternalMethods.get_prototype_of(value)

      [value | _] when is_integer(value) or is_float(value) ->
        InternalMethods.get_prototype_of(value)

      [value | _] when is_binary(value) ->
        InternalMethods.get_prototype_of(value)

      [value | _] when is_boolean(value) ->
        InternalMethods.get_prototype_of(value)

      [{:symbol, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      [{:symbol, _, _} = value | _] ->
        InternalMethods.get_prototype_of(value)

      _ ->
        throw(
          {:js_throw, Heap.make_error("Object.getPrototypeOf called on non-object", "TypeError")}
        )
    end
  end

  defp prototype_value?(nil), do: true
  defp prototype_value?({:obj, _}), do: true
  defp prototype_value?(_), do: false

  @ecma "20.1.2.4"
  static "defineProperty", length: 3, constructable: false do
    ObjectDescriptors.define_property(args)
  end

  @ecma "20.1.2.3"
  static "defineProperties", length: 2, constructable: false do
    ObjectDescriptors.define_properties(args)
  end

  @ecma "20.1.2.10"
  static "getOwnPropertyNames", length: 1 do
    ObjectEnumeration.own_property_names(args)
  end

  @ecma "20.1.2.8"
  static "getOwnPropertyDescriptor", length: 2 do
    ObjectDescriptors.own_property_descriptor(args)
  end

  @ecma "20.1.2.9"
  static "getOwnPropertyDescriptors", length: 1 do
    ObjectDescriptors.own_property_descriptors(args)
  end

  @ecma "20.1.2.7"
  static "fromEntries", length: 1 do
    from_entries(args)
  end

  @ecma "20.1.2.13"
  static "groupBy", length: 2 do
    group_by(args)
  end

  @ecma "20.1.2.11"
  static "getOwnPropertySymbols", length: 1 do
    case args do
      [target | _] when is_nullish(target) ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")}
        )

      [target | _] ->
        target
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(&is_symbol/1)
        |> Heap.wrap()

      _ ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")}
        )
    end
  end

  @ecma "20.1.2.14"
  static "hasOwn", length: 2 do
    case args do
      [target, _key | _] when is_nullish(target) ->
        throw(
          {:js_throw, Heap.make_error("Object.hasOwn called on null or undefined", "TypeError")}
        )

      [target, key | _] ->
        InternalMethods.own_property(target, PropertyKey.to_property_key(key)) != :undefined

      _ ->
        false
    end
  end

  @ecma "20.1.2.23"
  static "setPrototypeOf", length: 2 do
    case args do
      [obj | _] when is_nullish(obj) ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")}
        )

      [_obj, new_proto | _] ->
        unless prototype_value?(new_proto) do
          throw(
            {:js_throw,
             Heap.make_error("Object prototype may only be an object or null", "TypeError")}
          )
        end

        set_prototype_of(args)

      _ ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")}
        )
    end
  end

  defp set_prototype_of(args) do
    case args do
      [{:obj, ref} = obj, new_proto | _] ->
        case Heap.get_obj(ref, %{}) do
          %{proxy_target() => _target, proxy_handler() => _handler} ->
            if InternalMethods.set_prototype_of(obj, new_proto) do
              obj
            else
              throw(
                {:js_throw,
                 Heap.make_error("proxy setPrototypeOf trap returned false", "TypeError")}
              )
            end

          map when is_map(map) ->
            set_ordinary_prototype_or_throw!(obj, ref, new_proto)
            Heap.put_obj(ref, Map.put(map, proto(), new_proto))
            obj

          data when is_list(data) ->
            set_ordinary_prototype_or_throw!(obj, ref, new_proto)
            Heap.put_array_prop(ref, "__proto__", new_proto)
            obj

          {:qb_arr, _} ->
            set_ordinary_prototype_or_throw!(obj, ref, new_proto)
            Heap.put_array_prop(ref, "__proto__", new_proto)
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

  defp set_ordinary_prototype_or_throw!(obj, ref, new_proto) do
    cond do
      obj == Heap.get_object_prototype() and new_proto != InternalMethods.get_prototype_of(obj) ->
        throw({:js_throw, Heap.make_error("Cannot set immutable prototype", "TypeError")})

      match?({:obj, _}, new_proto) and Prototype.ordinary_chain_contains?(new_proto, ref) ->
        throw({:js_throw, Heap.make_error("Cannot create prototype cycle", "TypeError")})

      not Heap.extensible?(ref) and new_proto != InternalMethods.get_prototype_of(obj) ->
        throw(
          {:js_throw,
           Heap.make_error("Cannot set prototype of non-extensible object", "TypeError")}
        )

      true ->
        :ok
    end
  end

  defp from_entries([iterable | _]) do
    source_entries = entries_from_iterable(iterable)

    result =
      case QuickBEAM.VM.Runtime.ConstructorRegistry.class_proto("Object") do
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

  defp group_by([items, callback | _]) do
    unless QuickBEAM.VM.Builtin.callable?(callback) do
      throw({:js_throw, Heap.make_error("callback is not callable", "TypeError")})
    end

    result = Heap.wrap(%{proto() => :null_proto})
    {iter, next_fn} = Iterators.for_of_start(items)
    do_group_by(result, iter, next_fn, callback, 0)
  end

  defp group_by(_),
    do: throw({:js_throw, Heap.make_error("callback is not callable", "TypeError")})

  defp do_group_by(result, :undefined, _next_fn, _callback, _index), do: result

  defp do_group_by(result, iter, next_fn, callback, index) do
    {done?, value, next_iter} = Iterators.for_of_next(next_fn, iter)

    if done? do
      result
    else
      key = group_property_key(callback, value, index, iter)
      append_group_value(result, key, value)
      do_group_by(result, next_iter, next_fn, callback, index + 1)
    end
  end

  defp group_property_key(callback, value, index, iter) do
    callback
    |> Invocation.invoke_with_receiver([value, index], :undefined)
    |> PropertyKey.to_property_key()
  catch
    {:js_throw, error} ->
      Iterators.iterator_close(iter)
      throw({:js_throw, error})
  end

  defp append_group_value({:obj, _} = result, key, value) do
    case Get.get(result, key) do
      {:obj, ref} = array ->
        Heap.array_push(ref, [value])
        array

      _ ->
        Define.create_data_property_or_throw(result, key, Heap.wrap([value]))
    end
  end

  defp from_entries_property_key({:obj, _} = key) do
    case Get.get(key, {:symbol, "Symbol.toPrimitive"}) do
      primitive_fn when not is_nullish(primitive_fn) ->
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

    if not Value.nullish?(iterator_method) do
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
      return_fn when not is_nullish(return_fn) ->
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
        case Heap.get_obj(entry, %{}) |> WrappedPrimitive.value(:string) do
          {:ok, <<key::utf8, value::utf8, _::binary>>} -> [<<key::utf8>>, <<value::utf8>>]
          _ -> entry_pair_from_properties(entry)
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
end
