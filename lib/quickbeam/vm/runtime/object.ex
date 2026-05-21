defmodule QuickBEAM.VM.Runtime.Object do
  @moduledoc "Object static methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1, is_nullish: 1]
  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Semantics.{Iterators, Values}
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Get,
    OwnProperty,
    PropertyDescriptor,
    PropertyKey,
    Prototype,
    Put,
    Semantics,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.String, as: JSString

  builtin_definition("Object",
    constructor: &QuickBEAM.VM.Runtime.Globals.Constructors.object/2,
    length: 1,
    phase: :core,
    prototype_parent: nil,
    after_install: &__MODULE__.install_builtin/2
  )

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
        Heap.wrap(%{"__proto__" => object_proto})
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
       when is_boolean(value),
       do: Heap.wrap(%{WrappedPrimitive.slot(:boolean) => value, "__proto__" => boolean_proto})

  defp object_value(
         value,
         _object_proto,
         _boolean_proto,
         number_proto,
         _bigint_proto,
         _string_proto,
         _symbol_proto
       )
       when is_number(value),
       do: Heap.wrap(%{WrappedPrimitive.slot(:number) => value, "__proto__" => number_proto})

  defp object_value(
         {:bigint, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         bigint_proto,
         _string_proto,
         _symbol_proto
       ),
       do: Heap.wrap(%{WrappedPrimitive.slot(:bigint) => value, "__proto__" => bigint_proto})

  defp object_value(
         value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         string_proto,
         _symbol_proto
       )
       when is_binary(value),
       do: Heap.wrap(%{WrappedPrimitive.slot(:string) => value, "__proto__" => string_proto})

  defp object_value(
         {:symbol, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         symbol_proto
       ),
       do: Heap.wrap(%{WrappedPrimitive.slot(:symbol) => value, "__proto__" => symbol_proto})

  defp object_value(
         {:symbol, _, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         symbol_proto
       ),
       do: Heap.wrap(%{WrappedPrimitive.slot(:symbol) => value, "__proto__" => symbol_proto})

  defp object_value(
         _value,
         object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto,
         _string_proto,
         _symbol_proto
       ),
       do: Heap.wrap(%{"__proto__" => object_proto})

  @doc "Builds prototype data for object static methods."
  def build_prototype do
    ref = make_ref()

    Heap.put_obj(
      ref,
      Map.put(
        object heap: false do
          method "toString" do
            object_to_string(this)
          end

          method "toLocaleString" do
            object_to_locale_string(this)
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

          method "__defineGetter__" do
            define_accessor_property(args, this, :get)
          end

          method "__defineSetter__" do
            define_accessor_property(args, this, :set)
          end

          method "__lookupGetter__" do
            lookup_accessor_property(args, this, :get)
          end

          method "__lookupSetter__" do
            lookup_accessor_property(args, this, :set)
          end

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

  defp object_proto_get(target), do: Prototype.get(target)

  defp object_proto_set(_args, target) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp object_proto_set([proto | _], {:obj, ref} = target) do
    if proto == nil or match?({:obj, _}, proto) do
      cond do
        Prototype.get(target) == proto ->
          :ok

        target == Heap.get_object_prototype() and proto != nil ->
          throw({:js_throw, Heap.make_error("Cannot set immutable prototype", "TypeError")})

        target == Heap.get_object_prototype() ->
          :ok

        match?({:obj, _}, proto) and Prototype.ordinary_chain_contains?(proto, ref) ->
          throw({:js_throw, Heap.make_error("Cannot create prototype cycle", "TypeError")})

        not Heap.extensible?(ref) and Prototype.get(target) != proto ->
          throw(
            {:js_throw,
             Heap.make_error("Cannot set prototype of non-extensible object", "TypeError")}
          )

        true ->
          Prototype.set(target, proto)
      end
    end

    :undefined
  end

  defp object_proto_set([proto | _], target) do
    if proto == nil or match?({:obj, _}, proto) do
      Prototype.set(target, proto)
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
    Define.property(target, prop_key, desc_obj, desc)
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
    case OwnProperty.descriptor(obj, key) do
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
        lookup_accessor_in_chain(Prototype.get(obj), key, kind)
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
    do: OwnProperty.descriptor(target, key) != :undefined

  defp function_descriptor_present?({:closure, _, %QuickBEAM.VM.Function{}} = target, key),
    do: OwnProperty.descriptor(target, key) != :undefined

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

      {:regexp, _, _, ref} = regexp ->
        freeze_regexp(regexp, ref)
        regexp

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
        if is_object_like?(obj), do: Heap.prevent_extensions(obj)
        obj
    end
  end

  static "isExtensible", length: 1 do
    case hd(args) do
      {:obj, ref} -> Heap.extensible?(ref)
      {:builtin, "ThrowTypeError", _} -> false
      value -> if is_object_like?(value), do: Heap.extensible?(value), else: false
    end
  end

  static "seal", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj ->
        seal_object(obj)
        obj

      {:regexp, _, _, ref} = regexp ->
        seal_regexp(regexp, ref)
        regexp

      callable when is_tuple(callable) or is_struct(callable) ->
        if is_object_like?(callable), do: seal_callable(callable)
        callable

      obj ->
        obj
    end
  end

  static "isFrozen", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj -> frozen_object?(obj)
      value -> if is_object_like?(value), do: frozen_object_like?(value), else: true
    end
  end

  static "isSealed", length: 1 do
    case hd(args) do
      {:obj, _ref} = obj -> sealed_object?(obj)
      value -> if is_object_like?(value), do: sealed_object_like?(value), else: true
    end
  end

  defp freeze_callable(callable) do
    for key <- OwnProperty.descriptor_keys(callable) do
      case OwnProperty.descriptor(callable, key) do
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
      unless OwnProperty.descriptor(callable, key) == :undefined do
        callable
        |> callable_descriptor_attrs(key)
        |> Map.put(:configurable, false)
        |> then(&Heap.put_ctor_prop_desc(callable, key, &1))
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
      case OwnProperty.descriptor(regexp, key) do
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
          Value.nullish?(trap) ->
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
      Define.property(obj, key, Heap.wrap(desc), desc)
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
      unless OwnProperty.descriptor(regexp, key) == :undefined do
        regexp
        |> descriptor_attrs(key)
        |> Map.put(:configurable, false)
        |> then(&Heap.put_prop_desc(ref, key, &1))
      end
    end

    Heap.prevent_extensions(regexp)
  end

  defp descriptor_attrs(target, key) do
    case OwnProperty.descriptor(target, key) do
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
    case OwnProperty.descriptor(target, key) do
      {:obj, _} = desc ->
        Get.get(desc, "configurable") == false and Get.get(desc, "writable") != true

      _ ->
        false
    end
  end

  defp sealed_descriptor?(target, key) do
    case OwnProperty.descriptor(target, key) do
      {:obj, _} = desc -> Get.get(desc, "configurable") == false
      _ -> false
    end
  end

  defp object_extensible?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "isExtensible")

        if Value.nullish?(trap) do
          object_extensible?(target)
        else
          Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target]))
        end

      _ ->
        Heap.extensible?(ref)
    end
  end

  defp object_extensible?(_), do: true

  defp is_object_like?(value), do: Value.object_like?(value)

  defp property_value_for_descriptor(map, key) when is_map(map), do: Map.get(map, key)
  defp property_value_for_descriptor(_data, _key), do: :undefined

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
            Prototype.get({:obj, ref})

          {:qb_arr, _} ->
            Prototype.get({:obj, ref})

          list when is_list(list) ->
            Prototype.get({:obj, ref})

          _ ->
            nil
        end

      [{:qb_arr, _} = value | _] ->
        Prototype.get(value)

      [value | _] when is_list(value) ->
        Prototype.get(value)

      [{:builtin, _, _} = value | _] ->
        Prototype.get(value)

      [{:regexp, _, _} = value | _] ->
        Prototype.get(value)

      [{:regexp, _, _, _} = value | _] ->
        Prototype.get(value)

      [{:closure, _, _} = value | _] ->
        Prototype.get(value)

      [{:bound, _, _, _, _} = value | _] ->
        Prototype.get(value)

      [%QuickBEAM.VM.Function{} = value | _] ->
        Prototype.get(value)

      [value | _] when is_function(value) ->
        Prototype.get(value)

      [value | _] when is_integer(value) or is_float(value) ->
        Prototype.get(value)

      [value | _] when is_binary(value) ->
        Prototype.get(value)

      [value | _] when is_boolean(value) ->
        Prototype.get(value)

      [{:symbol, _} = value | _] ->
        Prototype.get(value)

      [{:symbol, _, _} = value | _] ->
        Prototype.get(value)

      _ ->
        throw(
          {:js_throw, Heap.make_error("Object.getPrototypeOf called on non-object", "TypeError")}
        )
    end
  end

  defp proxy_get_prototype_of(target, handler) do
    unless Value.object_like?(handler) do
      throw(
        {:js_throw,
         Heap.make_error("Cannot perform operation on a proxy with null handler", "TypeError")}
      )
    end

    trap = Get.get(handler, "getPrototypeOf")

    result =
      if Value.nullish?(trap) do
        Prototype.get(target)
      else
        Invocation.invoke_callback_or_throw(trap, [target], handler)
      end

    cond do
      not prototype_value?(result) ->
        proxy_prototype_invariant_error()

      not target_extensible_for_prototype?(target) and result != Prototype.get(target) ->
        proxy_prototype_invariant_error()

      true ->
        result
    end
  end

  defp proxy_set_prototype_of(target, handler, new_proto) do
    unless Value.object_like?(handler) do
      throw(
        {:js_throw,
         Heap.make_error("Cannot perform operation on a proxy with null handler", "TypeError")}
      )
    end

    trap = Get.get(handler, "setPrototypeOf")

    success? =
      if Value.nullish?(trap) do
        set_own_prototype(target, new_proto)
        true
      else
        Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target, new_proto], handler))
      end

    if success? and not target_extensible_for_prototype?(target) and
         new_proto != Prototype.get(target) do
      proxy_prototype_invariant_error()
    end

    success?
  end

  defp prototype_value?(nil), do: true
  defp prototype_value?({:obj, _}), do: true
  defp prototype_value?(_), do: false

  defp set_own_prototype(target, new_proto), do: Prototype.set(target, new_proto)

  defp target_extensible_for_prototype?({:obj, ref}), do: Heap.extensible?(ref)
  defp target_extensible_for_prototype?(_), do: true

  defp proxy_prototype_invariant_error do
    throw({:js_throw, Heap.make_error("proxy prototype trap violates invariant", "TypeError")})
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

  static "groupBy", length: 2 do
    group_by(args)
  end

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

  static "hasOwn", length: 2 do
    case args do
      [target, _key | _] when is_nullish(target) ->
        throw(
          {:js_throw, Heap.make_error("Object.hasOwn called on null or undefined", "TypeError")}
        )

      [target, key | _] ->
        OwnProperty.present?(target, PropertyKey.to_property_key(key))

      _ ->
        false
    end
  end

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
      obj == Heap.get_object_prototype() and new_proto != Prototype.get(obj) ->
        throw({:js_throw, Heap.make_error("Cannot set immutable prototype", "TypeError")})

      match?({:obj, _}, new_proto) and Prototype.ordinary_chain_contains?(new_proto, ref) ->
        throw({:js_throw, Heap.make_error("Cannot create prototype cycle", "TypeError")})

      not Heap.extensible?(ref) and new_proto != Prototype.get(obj) ->
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
      primitive_fn when primitive_fn != nil and primitive_fn != :undefined ->
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
      return_fn when return_fn != nil and return_fn != :undefined ->
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

  defp keys([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) or match?({:qb_arr, _}, data) do
      Heap.wrap(enumerable_keys(ref))
    else
      keys_from_map(ref, data)
    end
  end

  defp keys([target | _]) do
    if is_object_like?(target) do
      target
      |> OwnProperty.descriptor_keys()
      |> Enum.filter(&(is_binary(&1) and OwnProperty.enumerable?(target, &1)))
      |> Heap.wrap()
    else
      Heap.wrap([])
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

  defp get_own_property_names([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp get_own_property_names([{:obj, ref} | _]) do
    Heap.wrap(OwnProperty.descriptor_keys({:obj, ref}) |> Enum.filter(&is_binary/1))
  end

  defp get_own_property_names([target | _]) do
    target
    |> OwnProperty.descriptor_keys()
    |> Enum.filter(&is_binary/1)
    |> Heap.wrap()
  end

  defp get_own_property_names(_) do
    Heap.wrap([])
  end

  defp get_own_property_descriptors([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp get_own_property_descriptors([obj | _]) do
    ref = make_ref()
    keys = OwnProperty.descriptor_keys(obj)

    descriptors =
      Enum.reduce(keys, %{key_order() => descriptor_result_key_order(keys)}, fn key, acc ->
        case get_own_property_descriptor([obj, key]) do
          :undefined -> acc
          desc -> Map.put(acc, key, desc)
        end
      end)

    Heap.put_obj(ref, descriptors)
    {:obj, ref}
  end

  defp get_own_property_descriptors(_), do: Heap.wrap(%{})

  defp descriptor_result_key_order(keys) do
    if Enum.all?(keys, &is_symbol/1), do: keys, else: Enum.reverse(keys)
  end

  defp enumerable_keys(ref) do
    data = Heap.get_obj(ref, %{})

    case data do
      {:qb_arr, arr} ->
        Semantics.enumerable_array_keys(ref, arr, array_prop_keys(ref))

      list when is_list(list) ->
        (array_indices(list) ++ array_prop_keys(ref)) |> Runtime.sort_numeric_keys()

      map when is_map(map) and is_map_key(map, proxy_target()) ->
        {:obj, ref}
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(&(is_binary(&1) and proxy_enumerable_key?({:obj, ref}, &1)))

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
      is_binary(key) and not internal?(key) and
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
    raw_key = if Map.has_key?(map, key), do: key, else: integer_property_key(key)

    raw_key = if raw_key != :error and Map.has_key?(map, raw_key), do: raw_key, else: key

    is_binary(key) and not internal_namespace?(key) and Map.has_key?(map, raw_key) and
      not match?(%{enumerable: false}, Heap.get_prop_desc(ref, raw_key))
  end

  defp enumerable_value(obj, map, key) when is_map(map) do
    raw_key = integer_property_key(key)

    cond do
      match?({:accessor, _, _}, Map.get(map, key)) -> Get.get(obj, key)
      Map.has_key?(map, key) -> Map.get(map, key)
      raw_key != :error and match?({:accessor, _, _}, Map.get(map, raw_key)) -> Get.get(obj, key)
      raw_key != :error and Map.has_key?(map, raw_key) -> Map.get(map, raw_key)
      true -> Get.get(obj, key)
    end
  end

  defp enumerable_value(obj, _data, key), do: Get.get(obj, key)

  defp integer_property_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> :error
    end
  end

  defp values([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp values([{:obj, _ref} = obj | _]) do
    obj
    |> OwnProperty.descriptor_keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn key ->
      case OwnProperty.descriptor(obj, key) do
        {:obj, _} = desc ->
          if Get.get(desc, "enumerable") == true, do: [Get.get(obj, key)], else: []

        _ ->
          []
      end
    end)
    |> Heap.wrap()
  end

  defp values([string | _]) when is_binary(string) do
    string
    |> JSString.utf16_code_units()
    |> Heap.wrap()
  end

  defp values([map | _]) when is_map(map), do: Map.values(map)
  defp values(_), do: []

  defp entries([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp entries([{:obj, _ref} = obj | _]) do
    keys = obj |> OwnProperty.descriptor_keys() |> Enum.filter(&is_binary/1)
    Heap.wrap(enumerable_descriptor_pairs(obj, keys))
  end

  defp entries([callable | _]) when is_tuple(callable) or is_struct(callable) do
    Heap.wrap(enumerable_descriptor_pairs(callable, OwnProperty.descriptor_keys(callable)))
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

  defp enumerable_descriptor_pairs(target, keys) do
    keys
    |> Enum.reduce([], fn key, acc ->
      case OwnProperty.descriptor(target, key) do
        :undefined ->
          acc

        desc ->
          if Get.get(desc, "enumerable") == true do
            [Heap.wrap([key, Get.get(target, key)]) | acc]
          else
            acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp assign([target | _sources]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp assign([target | sources]) do
    target_obj = to_assign_target(target)

    Enum.reduce(sources, target_obj, fn
      source, target_obj when is_nullish(source) ->
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
        with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(map, :string),
             {:ok, index} <- PropertyKey.array_index(key) do
          index < Get.string_length(string)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp target_has_own?(ref, key), do: target_own_value(ref, key) != :missing

  defp target_own_value(ref, key) do
    case Heap.raw_fetch(Heap.get_obj_raw(ref), key) do
      {:ok, value} -> value
      :error -> :missing
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
      PropertyKey.property_key?(key) and proxy_assign_enumerable?(target, descriptor_trap, key)
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

  defp assign_internal_key?(key), do: internal_slot?(key)

  defp define_property([{:obj, _} = obj, key, {:obj, desc_ref} = desc_obj | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    Define.property(obj, key, desc_obj, desc)
  end

  defp define_property([{:regexp, _, _, ref} = regexp, key, {:obj, desc_ref} = desc_obj | _]) do
    key = normalize_well_known_symbol(key)
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

  defp define_property([{:obj, _} = obj, key, desc | _]) when is_map(desc) do
    Define.property(obj, key, Heap.wrap(desc), desc)
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

  defp define_property([{:bound, _, _, _, _} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  defp define_property([%QuickBEAM.VM.Function{} = fun, key, {:obj, desc_ref} | _]) do
    define_callable_property(fun, key, desc_ref)
  end

  defp define_property([{:builtin, _, _} = b, key, {:obj, desc_ref} | _]) do
    define_static_property(b, key, desc_ref)
    b
  end

  defp define_property(_args) do
    throw({:js_throw, Heap.make_error("Object.defineProperty called on non-object", "TypeError")})
  end

  defp normalize_well_known_symbol(key), do: PropertyKey.normalize(key)

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

  defp define_properties([target, _props | _]) when is_nullish(target) do
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
    for key <- define_properties_keys(props, props_ref) do
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

  defp define_properties([_obj, props | _]) when is_nullish(props) do
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

  defp define_properties_keys(props, props_ref) do
    case Heap.get_obj(props_ref, %{}) do
      map when is_map(map) and is_map_key(map, proxy_target()) ->
        props
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(fn key ->
          case OwnProperty.descriptor(props, key) do
            {:obj, _} = desc -> Values.truthy?(Get.get(desc, "enumerable"))
            _ -> false
          end
        end)

      _ ->
        enumerable_keys(props_ref)
    end
  end

  defp get_own_property_descriptor([target, _key | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp get_own_property_descriptor([target, key | _]) do
    OwnProperty.descriptor(target, key)
  end

  defp get_own_property_descriptor([target]), do: OwnProperty.descriptor(target, :undefined)
  defp get_own_property_descriptor(_), do: :undefined

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, i} -> Integer.to_string(i) end)
  end
end
