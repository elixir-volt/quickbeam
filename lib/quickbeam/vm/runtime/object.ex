defmodule QuickBEAM.VM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1, is_nullish: 1]
  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.JSThrow

  alias QuickBEAM.VM.ObjectModel.{
    Get,
    InternalMethods,
    OwnProperty,
    PropertyKey,
    Prototype,
    Semantics,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Object.{Assign, Descriptors, Enumeration, Entries, Integrity}
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

    InternalMethods.own_property_present?(target, prop_name) or
      function_descriptor_present?(target, prop_name)
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

    InternalMethods.enumerable_own_property?(target, prop_name)
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
    Enumeration.keys(args)
  end

  @ecma "20.1.2.24"
  static "values", length: 1 do
    Enumeration.values(args)
  end

  @ecma "20.1.2.5"
  static "entries", length: 1 do
    Enumeration.entries(args)
  end

  @ecma "20.1.2.1"
  static "assign", length: 2, constructable: false do
    Assign.assign(args)
  end

  @ecma "20.1.2.6"
  static "freeze", length: 1 do
    args |> arg(0, :undefined) |> Integrity.freeze()
  end

  @ecma "20.1.2.17"
  static "preventExtensions", length: 1 do
    args |> arg(0, :undefined) |> Integrity.prevent_extensions()
  end

  @ecma "20.1.2.16"
  static "isExtensible", length: 1 do
    args |> arg(0, :undefined) |> Integrity.extensible?()
  end

  @ecma "20.1.2.22"
  static "seal", length: 1 do
    args |> arg(0, :undefined) |> Integrity.seal()
  end

  @ecma "20.1.2.17"
  static "isFrozen", length: 1 do
    args |> arg(0, :undefined) |> Integrity.frozen?()
  end

  @ecma "20.1.2.18"
  static "isSealed", length: 1 do
    args |> arg(0, :undefined) |> Integrity.sealed?()
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
      [props | _] -> Descriptors.define_properties([obj, props])
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
    Descriptors.define_property(args)
  end

  @ecma "20.1.2.3"
  static "defineProperties", length: 2, constructable: false do
    Descriptors.define_properties(args)
  end

  @ecma "20.1.2.10"
  static "getOwnPropertyNames", length: 1 do
    Enumeration.own_property_names(args)
  end

  @ecma "20.1.2.8"
  static "getOwnPropertyDescriptor", length: 2 do
    Descriptors.own_property_descriptor(args)
  end

  @ecma "20.1.2.9"
  static "getOwnPropertyDescriptors", length: 1 do
    Descriptors.own_property_descriptors(args)
  end

  @ecma "20.1.2.7"
  static "fromEntries", length: 1 do
    Entries.from_entries(args)
  end

  @ecma "20.1.2.13"
  static "groupBy", length: 2 do
    Entries.group_by(args)
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
end
