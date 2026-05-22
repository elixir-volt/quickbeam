defmodule QuickBEAM.VM.ObjectModel.Get do
  @moduledoc """
  JavaScript property resolution: own properties, prototype chain, and getters.

  Spec:
  - ECMA-262 §7.3.2 Get
  - ECMA-262 §10.1.8 [[Get]]
  - ECMA-262 §10.1.8.1 OrdinaryGet
  - ECMA-262 §10.4 built-in exotic object internal methods where represented by VM values
  """

  import Bitwise, only: [band: 2]
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Execution.{ClosureCells, RegexpState}
  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.Runtime

  alias QuickBEAM.VM.Runtime.{
    Boolean,
    Function,
    Number,
    Object,
    RegExp,
    TypedArray
  }

  alias QuickBEAM.VM.ObjectModel.{
    ArrayExoticGet,
    BuiltinExoticGet,
    BuiltinFunctionGet,
    DateExoticGet,
    FunctionExoticGet,
    FunctionPrototypeGet,
    OwnProperty,
    PrimitiveExoticGet,
    PrimitiveWrapperGet,
    PropertyKey,
    RegExpExoticGet,
    Prototype,
    ProxyGet,
    Semantics,
    SymbolExoticGet,
    TypedArrayExoticGet,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime.ArrayBuffer
  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.String, as: JSString

  @doc "Reads a JavaScript property, including own lookup, prototype lookup, and getter invocation."
  def get(value, key) when is_binary(key), do: get(value, key, value)

  def get(value, key) when is_integer(key),
    do: get(value, Integer.to_string(key))

  def get({:obj, _} = value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)

  def get({:obj, _} = value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, PropertyKey.normalize(sym_key))

  def get({:regexp, _, _, _} = value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)

  def get({:regexp, _, _, _} = value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, PropertyKey.normalize(sym_key))

  def get({:regexp, _, _} = value, {:symbol, _} = sym_key), do: get_symbol(value, sym_key)

  def get({:regexp, _, _} = value, {:symbol, _, _} = sym_key),
    do: get_symbol(value, PropertyKey.normalize(sym_key))

  def get(value, {:symbol, "Symbol.hasInstance"} = sym_key),
    do: get_callable_symbol(value, sym_key)

  def get(value, {:symbol, "Symbol.hasInstance", _} = sym_key),
    do: get_callable_symbol(value, PropertyKey.normalize(sym_key))

  def get(value, {:symbol, _} = sym_key) do
    if QuickBEAM.VM.Builtin.callable?(value),
      do: get_callable_symbol(value, sym_key),
      else: get_symbol(value, sym_key)
  end

  def get(value, {:symbol, _, _} = sym_key),
    do: get(value, PropertyKey.normalize(sym_key))

  def get(_, _), do: :undefined

  def get(value, key, receiver) when is_integer(key),
    do: get(value, Integer.to_string(key), receiver)

  def get({:obj, ref} = value, key, receiver) when is_binary(key) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => target, proxy_handler() => handler} = proxy ->
        ProxyGet.dispatch(proxy, target, handler, key, receiver, &ordinary_get/3, &target_slot/2)

      _ ->
        ordinary_get(value, key, receiver)
    end
  end

  def get(value, key, receiver) when is_binary(key), do: ordinary_get(value, key, receiver)

  defp ordinary_get(value, key, receiver) do
    case get_own_with_receiver(value, key, receiver) do
      :undefined ->
        if explicit_undefined_own?(value, key) do
          :undefined
        else
          result = get_prototype_raw(value, key)

          case result do
            {:accessor, getter, _} when getter != nil -> call_getter(getter, receiver)
            {:accessor, nil, _} -> :undefined
            _ -> result
          end
        end

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, receiver)

      {:accessor, nil, _} ->
        :undefined

      val ->
        val
    end
  end

  defp get_own_with_receiver({:obj, ref} = value, key, receiver) do
    case Heap.get_obj_raw(ref) do
      map when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, {:accessor, getter, _setter}} when getter != nil -> call_getter(getter, receiver)
          {:ok, {:accessor, nil, _setter}} -> :undefined
          _ -> get_own(value, key)
        end

      _ ->
        get_own(value, key)
    end
  end

  defp get_own_with_receiver(value, key, _receiver), do: get_own(value, key)

  defp array_prototype_raw?(raw), do: Semantics.array_prototype_object?(raw)

  defp raw_keys(raw) when is_map(raw), do: Map.keys(raw)
  defp raw_keys(raw), do: raw |> Heap.shape_offsets() |> Map.keys()

  defp array_prototype_length(ref) do
    stored_length = Heap.get_array_prop(ref, "length")

    raw = Heap.get_obj_raw(ref)

    if array_prototype_raw?(raw) do
      if is_integer(stored_length),
        do: stored_length,
        else: array_prototype_index_length(raw_keys(raw))
    end
  end

  defp array_prototype_index_length(keys) do
    keys
    |> Enum.reduce(0, fn key, length ->
      case array_index_key(key) do
        index when is_integer(index) -> max(length, index + 1)
        nil -> length
      end
    end)
  end

  defp array_index_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> nil
    end
  end

  def function_prototype_has_own?(key) do
    case Heap.get_func_proto() do
      {:obj, ref} ->
        match?({:ok, _}, Heap.raw_fetch(Heap.get_obj_raw(ref), key))

      _ ->
        false
    end
  end

  defp get_callable_symbol(value, sym_key) do
    if QuickBEAM.VM.Builtin.callable?(value) do
      case get_own(value, sym_key) do
        :undefined ->
          FunctionPrototypeGet.fallback(get_from_prototype(value, sym_key), value, sym_key)

        {:accessor, getter, _} when getter != nil ->
          call_getter(getter, value)

        {:accessor, nil, _} ->
          :undefined

        val ->
          val
      end
    else
      get_own(value, sym_key)
    end
  end

  defp get_symbol(value, sym_key) do
    case get_own(value, sym_key) do
      :undefined ->
        if explicit_undefined_own?(value, sym_key) do
          :undefined
        else
          case get_prototype_raw(value, sym_key) do
            {:accessor, getter, _} when getter != nil -> call_getter(getter, value)
            {:accessor, nil, _} -> :undefined
            val -> val
          end
        end

      {:accessor, getter, _} when getter != nil ->
        call_getter(getter, value)

      val ->
        val
    end
  end

  @doc "Invokes a getter function with the provided receiver."
  def call_getter(fun, this_obj) do
    Invocation.invoke_with_receiver(fun, [], this_obj)
  end

  def regexp_flags(bytecode) when is_binary(bytecode) do
    case regexp_header_bytes(bytecode) do
      {flags_byte, unicode_sets_byte} ->
        base =
          [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}, {64, "d"}]
          |> Enum.reduce("", fn {bit, ch}, acc ->
            if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
          end)

        if band(unicode_sets_byte, 1) != 0, do: base <> "v", else: base

      :error ->
        ""
    end
  end

  def regexp_flags(_), do: ""

  defp regexp_header_bytes(bytecode) do
    case regexp_latin1_bytes(bytecode, 2, []) do
      [flags_byte, unicode_sets_byte] -> {flags_byte, unicode_sets_byte}
      [flags_byte] -> {flags_byte, 0}
      _ -> :error
    end
  end

  defp regexp_latin1_bytes(_bytecode, 0, acc), do: Enum.reverse(acc)
  defp regexp_latin1_bytes(<<>>, _count, acc), do: Enum.reverse(acc)

  defp regexp_latin1_bytes(<<cp::utf8, rest::binary>>, count, acc) when cp <= 0xFF,
    do: regexp_latin1_bytes(rest, count - 1, [cp | acc])

  defp regexp_latin1_bytes(<<byte, rest::binary>>, count, acc),
    do: regexp_latin1_bytes(rest, count - 1, [byte | acc])

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
  def string_length(s), do: JSString.utf16_length(s)

  @doc "Returns the JavaScript `length` value for array-like, string, and function values."
  def length_of(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj_raw(ref) do
          {:qb_arr, arr} ->
            array_prototype_length(ref) || virtual_array_length(ref) || :array.size(arr)

          list when is_list(list) ->
            array_prototype_length(ref) || virtual_array_length(ref) || length(list)

          raw when is_tuple(raw) ->
            if array_prototype_raw?(raw) do
              array_prototype_length(ref) || 0
            else
              case Heap.raw_fetch(raw, "length") do
                {:ok, value} ->
                  shape_value(value, {:obj, ref})

                :error ->
                  inherited_or_wrapped_length({:obj, ref}, wrapped_raw_length(raw))
              end
            end

          %{typed_array() => true} ->
            obj = {:obj, ref}

            if TypedArray.out_of_bounds?(obj),
              do: 0,
              else: TypedArray.element_count(obj)

          map when is_map(map) ->
            if array_prototype_raw?(map) do
              array_prototype_length(ref) || 0
            else
              case Map.fetch(map, "length") do
                {:ok, _} -> get_map_property(map, "length", {:obj, ref})
                :error -> inherited_or_wrapped_length({:obj, ref}, wrapped_map_length(map))
              end
            end

          _ ->
            0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      string when is_binary(string) ->
        string_length(string)

      %QuickBEAM.VM.Function{} = fun ->
        callable_length_of(fun, fun.defined_arg_count)

      {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure ->
        callable_length_of(closure, callable_length_of(fun, fun.defined_arg_count))

      {:bound, len, _, _, _} = bound ->
        callable_length_of(bound, len)

      {:builtin, _, _} = builtin ->
        callable_length_of(builtin, QuickBEAM.VM.Builtin.declared_length(builtin))

      _ ->
        :undefined
    end
  end

  # ── Own property lookup ──

  defp callable_length_of(callable, default) do
    case Map.get(Heap.get_ctor_statics(callable), "length", :not_found) do
      :deleted -> 0
      :not_found -> default
      value -> value
    end
  end

  defp virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp wrapped_raw_length(raw), do: PrimitiveWrapperGet.raw_length(raw)

  defp wrapped_map_length(map), do: PrimitiveWrapperGet.map_length(map)

  defp wrapped_raw_proto_property(raw, key), do: PrimitiveWrapperGet.raw_proto_property(raw, key)

  defp prototype_object_property(%{"constructor" => {:builtin, "Date", _}}, key),
    do: JSDate.proto_property(key)

  defp prototype_object_property(_map, _key), do: :undefined

  defp date_proto_property(map, key), do: DateExoticGet.proto_property(map, key)

  defp string_proto_property(key), do: PrimitiveWrapperGet.string_proto_property(key)

  defp wrapped_proto_property(map, key), do: PrimitiveWrapperGet.map_proto_property(map, key)

  defp inherited_or_wrapped_length(obj, fallback) do
    case get(obj, "length") do
      :undefined -> fallback
      value -> value
    end
  end

  defp shape_value({:accessor, getter, _setter}, receiver) when getter != nil,
    do: call_getter(getter, receiver)

  defp shape_value({:accessor, nil, _setter}, _receiver), do: :undefined
  defp shape_value(value, _receiver), do: value

  defp get_wrapped_or_map_property(map, key, receiver) do
    if WrappedPrimitive.type(map) in [:string, :number, :boolean] and Map.has_key?(map, key) do
      get_map_property(map, key, receiver)
    else
      case wrapped_proto_property(map, key) do
        :undefined -> get_map_property(map, key, receiver)
        val -> val
      end
    end
  end

  defp get_map_property(map, key, receiver) do
    case Map.fetch(map, key) do
      {:ok, {:accessor, getter, _setter}} when getter != nil -> call_getter(getter, receiver)
      {:ok, val} -> val
      :error -> :undefined
    end
  end

  defp get_own({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      nil ->
        :undefined

      %{proxy_target() => target, proxy_handler() => handler} = proxy ->
        ProxyGet.dispatch(
          proxy,
          target,
          handler,
          key,
          {:obj, ref},
          &ordinary_get/3,
          &target_slot/2
        )

      {:qb_arr, _} = arr ->
        case Heap.get_regexp_result(ref) do
          %{^key => val} -> val
          _ -> array_own_property(ref, arr, key)
        end

      list when is_list(list) ->
        case Heap.get_regexp_result(ref) do
          %{^key => val} -> val
          _ -> array_own_property(ref, list, key)
        end

      raw when is_tuple(raw) ->
        cond do
          Heap.shape?(raw) and key == "__proto__" ->
            Heap.shape_proto(raw) || :undefined

          Heap.shape?(raw) and key == "length" and array_prototype_raw?(raw) ->
            array_prototype_length(ref) || 0

          Heap.shape?(raw) ->
            case Heap.raw_fetch(raw, key) do
              {:ok, value} -> value
              :error -> wrapped_raw_proto_property(raw, key)
            end

          true ->
            :undefined
        end

      %{date_ms() => _} = map ->
        case get_map_property(map, key, {:obj, ref}) do
          :undefined -> date_proto_property(map, key)
          val -> val
        end

      %{typed_array() => true} = map ->
        obj = {:obj, ref}

        case key do
          "length" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.element_count(obj)

          "byteLength" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.current_byte_length(obj)

          "byteOffset" ->
            if TypedArray.out_of_bounds?(obj), do: 0, else: Map.get(map, "byteOffset", 0)

          _ ->
            typed_array_property(obj, map, key)
        end

      %{buffer() => _} = map ->
        case Map.get(map, key) do
          nil -> ArrayBuffer.proto_property(key)
          val -> val
        end

      map when is_map(map) and key == "length" ->
        if Semantics.array_prototype_object?(map) do
          array_prototype_length(ref) || 0
        else
          case prototype_object_property(map, key) do
            :undefined -> get_wrapped_or_map_property(map, key, {:obj, ref})
            val -> val
          end
        end

      map when is_map(map) ->
        cond do
          Heap.get_prop_desc(ref, key) == :deleted ->
            :undefined

          key == "__proto__" and Map.has_key?(map, :__internal_proto__) and Map.has_key?(map, key) ->
            get_map_property(map, key, {:obj, ref})

          true ->
            case prototype_object_property(map, key) do
              :undefined -> get_wrapped_or_map_property(map, key, {:obj, ref})
              val -> val
            end
        end
    end
  end

  defp get_own({:qb_arr, arr}, "length"), do: :array.size(arr)

  defp get_own({:qb_arr, arr}, key) when is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} ->
        if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined

      :error ->
        :undefined
    end
  end

  defp get_own(list, "length") when is_list(list), do: length(list)

  defp get_own(list, key) when is_list(list) and is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> Enum.at(list, idx, :undefined)
      :error -> :undefined
    end
  end

  defp get_own(s, "length") when is_binary(s), do: string_length(s)

  defp get_own(s, key) when is_binary(s) do
    case PropertyKey.array_index(key) do
      {:ok, index} when index < 4_294_967_295 -> JSString.utf16_code_unit_at(s, index)
      _ -> JSString.proto_property(key)
    end
  end

  defp get_own(n, _) when is_number(n), do: :undefined
  defp get_own(true, _), do: :undefined
  defp get_own(false, _), do: :undefined
  defp get_own(nil, _), do: :undefined
  defp get_own(:undefined, _), do: :undefined

  defp get_own({:builtin, _, _} = builtin, key),
    do: BuiltinFunctionGet.own_property(builtin, key, &call_getter/2)

  defp get_own({:regexp, _, _, ref} = regexp, "flags") do
    case RegexpState.fetch(ref, "flags") do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> regexp_instance_property(regexp, "flags")
    end
  end

  defp get_own({:regexp, _bytecode, source, ref} = regexp, "source") when is_binary(source) do
    case RegexpState.fetch(ref, "source") do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> regexp_instance_property(regexp, "source")
    end
  end

  defp get_own({:regexp, _, _, ref} = regexp, "lastIndex") do
    case RegexpState.fetch(ref, "lastIndex") do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> 0
    end
  end

  defp get_own({:regexp, _, _} = regexp, "flags"), do: regexp_instance_property(regexp, "flags")

  defp get_own({:regexp, _bytecode, source} = regexp, "source") when is_binary(source),
    do: regexp_instance_property(regexp, "source")

  defp get_own({:regexp, _, _}, "lastIndex"), do: 0

  defp get_own({:regexp, _, _, ref} = regexp, key) do
    case RegexpState.fetch(ref, key) do
      {:ok, value} -> regexp_state_value(value, regexp)
      :error -> regexp_instance_property(regexp, key)
    end
  end

  defp get_own({:regexp, _, _}, key), do: regexp_prototype_property(key)

  defp get_own(%QuickBEAM.VM.Function{} = fun, key),
    do: FunctionExoticGet.own_property(fun, key, &call_getter/2)

  defp get_own({:closure, _, %QuickBEAM.VM.Function{}} = closure, key),
    do: FunctionExoticGet.own_property(closure, key, &call_getter/2)

  defp get_own({:symbol, _} = symbol, key), do: SymbolExoticGet.own_property(symbol, key)
  defp get_own({:symbol, _, _} = symbol, key), do: SymbolExoticGet.own_property(symbol, key)

  defp get_own({:bound, _, _, _, _} = bound, key),
    do: FunctionExoticGet.own_property(bound, key, &call_getter/2)

  defp get_own(_, _), do: :undefined

  def own(value, key), do: get_own(value, key)

  defp regexp_state_value({:accessor, getter, _}, receiver) when getter != nil,
    do: call_getter(getter, receiver)

  defp regexp_state_value({:accessor, nil, _}, _receiver), do: :undefined
  defp regexp_state_value(value, _receiver), do: value

  defp regexp_instance_property(_regexp, key)
       when key in [
              "source",
              "flags",
              "hasIndices",
              "global",
              "ignoreCase",
              "multiline",
              "dotAll",
              "unicode",
              "unicodeSets",
              "sticky"
            ] do
    RegExp.proto_accessor(key)
  end

  defp regexp_instance_property(regexp, key), do: RegExpExoticGet.instance_property(regexp, key)

  defp regexp_prototype_property(key), do: RegExpExoticGet.prototype_property(key)

  defp typed_array_property(obj, map, key),
    do: TypedArrayExoticGet.property(obj, map, key, fn -> get_map_property(map, key, obj) end)

  defp target_slot({:obj, target_ref}, key) do
    case Heap.get_obj(target_ref, %{}) do
      map when is_map(map) -> Map.get(map, key, :undefined)
      _ -> get_own({:obj, target_ref}, key)
    end
  end

  defp target_slot(_target, _key), do: :undefined

  defp array_own_property(ref, array_data, "length") do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> get_own(array_data, "length")
    end
  end

  defp array_own_property(ref, array_data, key) do
    with {:ok, idx} <- PropertyKey.array_index(key),
         len when is_integer(len) <- virtual_array_length(ref),
         true <- idx >= len do
      :undefined
    else
      _ ->
        case mapped_argument_value(ref, key) do
          {:mapped, value} ->
            value

          :not_mapped ->
            case Heap.get_array_prop(ref, key) do
              :undefined ->
                own_value = get_own(array_data, key)

                if own_value == :undefined and Heap.get_prop_desc(ref, key) == nil do
                  get_from_prototype({:obj, ref}, key)
                else
                  own_value
                end

              value ->
                value
            end
        end
    end
  end

  defp mapped_argument_value(ref, key) do
    with {:ok, idx} <- PropertyKey.array_index(key),
         false <- deleted_argument?(ref, idx),
         mapped when is_map(mapped) <- Heap.get_array_prop(ref, "__mapped_arguments__"),
         {:cell, _} = cell <- Map.get(mapped, idx) do
      {:mapped, ClosureCells.read(cell)}
    else
      _ -> :not_mapped
    end
  end

  defp deleted_argument?(ref, idx) do
    case Heap.get_array_prop(ref, "__deleted_args__") do
      %MapSet{} = deleted -> MapSet.member?(deleted, idx)
      _ -> false
    end
  end

  # ── Prototype chain ──

  defp get_prototype_raw({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      raw when is_tuple(raw) ->
        if Heap.shape?(raw) do
          case Heap.shape_proto(raw) do
            {:obj, _pref} = proto ->
              case prototype_property_lookup_with_receiver(proto, key, {:obj, ref}) do
                {:found, value} -> value
                :not_found -> get_default_object_prototype({:obj, ref}, key)
              end

            nil ->
              get_default_object_prototype({:obj, ref}, key)

            :null_proto ->
              :undefined

            proto ->
              get_from_prototype(proto, key)
          end
        else
          get_from_prototype({:obj, ref}, key)
        end

      map when is_map(map) and is_map_key(map, proto()) ->
        proto = Map.get(map, :__internal_proto__, Map.get(map, proto()))

        proto_result =
          case proto do
            {:obj, _} -> prototype_property_lookup_with_receiver(proto, key, {:obj, ref})
            _ -> :not_found
          end

        type_result =
          cond do
            match?({:found, _}, proto_result) ->
              proto_result

            true ->
              BuiltinExoticGet.map_proto_property(map, key)
          end

        case type_result do
          {:found, value} ->
            value

          value when value != :undefined ->
            value

          _ ->
            case proto do
              {:obj, _pref} = proto ->
                prototype_property_with_receiver(proto, key, {:obj, ref})

              :null_proto ->
                :undefined

              _ ->
                get_from_prototype(proto, key)
            end
        end

      _ ->
        get_from_prototype({:obj, ref}, key)
    end
  end

  defp get_prototype_raw(value, key), do: get_from_prototype(value, key)

  defp explicit_undefined_own?({:regexp, _, _, ref}, key) do
    RegexpState.has_property?(ref, key)
  end

  defp explicit_undefined_own?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:qb_arr, _} ->
        Heap.get_prop_desc(ref, key) != nil

      data when is_list(data) ->
        Heap.get_prop_desc(ref, key) != nil

      raw when is_tuple(raw) ->
        Heap.shape?(raw) and match?({:ok, _}, Heap.raw_fetch(raw, key))

      %{typed_array() => true} ->
        match?({:ok, _}, PropertyKey.array_index(key)) or
          Map.has_key?(Heap.get_obj(ref, %{}), key)

      map when is_map(map) ->
        not Map.has_key?(map, proxy_target()) and Map.has_key?(map, key)

      _ ->
        false
    end
  end

  defp explicit_undefined_own?(value, key) when is_tuple(value) or is_struct(value),
    do: Heap.get_ctor_prop_desc(value, key) != nil

  defp explicit_undefined_own?(_value, _key), do: false

  defp get_from_prototype({:obj, ref}, key) do
    case Heap.get_obj(ref) do
      {:qb_arr, _} ->
        if Heap.get_array_prop(ref, "__arguments__") == true do
          arguments_proto_property({:obj, ref}, key)
        else
          array_proto_property({:obj, ref}, key)
        end

      list when is_list(list) ->
        if Heap.get_array_prop(ref, "__arguments__") == true do
          arguments_proto_property({:obj, ref}, key)
        else
          array_proto_property({:obj, ref}, key)
        end

      map when is_map(map) ->
        cond do
          Map.has_key?(map, proxy_target()) and
              QuickBEAM.VM.Builtin.callable?(Map.get(map, proxy_target())) ->
            FunctionPrototypeGet.fallback(:undefined, Map.get(map, proxy_target()), key)

          (builtin = BuiltinExoticGet.map_proto_property(map, key)) != :undefined ->
            builtin

          Map.has_key?(map, :__internal_proto__) ->
            prototype_property_with_receiver(Map.get(map, :__internal_proto__), key, {:obj, ref})

          Map.get(map, proto()) == :null_proto ->
            :undefined

          Map.has_key?(map, proto()) ->
            prototype_property_with_receiver(Map.get(map, proto()), key, {:obj, ref})

          true ->
            get_default_object_prototype({:obj, ref}, key)
        end

      _ ->
        :undefined
    end
  end

  defp get_from_prototype({:qb_arr, _}, "constructor") do
    Map.get(Runtime.global_bindings(), "Array", :undefined)
  end

  defp get_from_prototype({:qb_arr, _}, key), do: array_proto_property(key)

  defp get_from_prototype(list, "constructor") when is_list(list) do
    Map.get(Runtime.global_bindings(), "Array", :undefined)
  end

  defp get_from_prototype(list, key) when is_list(list), do: array_proto_property(key)

  defp get_from_prototype(s, key) when is_binary(s),
    do: primitive_or_class_proto(string_proto_property(key), key, "String", s)

  defp get_from_prototype(n, key) when is_number(n),
    do: primitive_or_class_proto(Number.proto_property(key), key, "Number", n)

  defp get_from_prototype(n, key) when n in [:nan, :infinity, :neg_infinity],
    do: primitive_or_class_proto(Number.proto_property(key), key, "Number", n)

  defp get_from_prototype(true, key),
    do: primitive_or_class_proto(Boolean.proto_property(key), key, "Boolean", true)

  defp get_from_prototype(false, key),
    do: primitive_or_class_proto(Boolean.proto_property(key), key, "Boolean", false)

  defp get_from_prototype({:symbol, _, _} = receiver, key),
    do: primitive_or_class_proto(:undefined, key, "Symbol", receiver)

  defp get_from_prototype({:symbol, _} = receiver, key),
    do: primitive_or_class_proto(:undefined, key, "Symbol", receiver)

  defp get_from_prototype({:bigint, _} = receiver, key),
    do: primitive_or_class_proto(:undefined, key, "BigInt", receiver)

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, "constructor"),
    do: FunctionPrototypeGet.constructor(f)

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, {:symbol, "Symbol.toStringTag"} = key),
    do: FunctionPrototypeGet.to_string_tag(f, key)

  defp get_from_prototype(%QuickBEAM.VM.Function{} = f, key),
    do: FunctionPrototypeGet.own_or_parent(f, key)

  defp get_from_prototype({:closure, _, %QuickBEAM.VM.Function{} = f}, "constructor"),
    do: FunctionPrototypeGet.constructor(f)

  defp get_from_prototype(
         {:closure, _, %QuickBEAM.VM.Function{}} = closure,
         {:symbol, "Symbol.toStringTag"} = key
       ),
       do: FunctionPrototypeGet.to_string_tag(closure, key)

  defp get_from_prototype({:closure, _, %QuickBEAM.VM.Function{}} = c, key),
    do: FunctionPrototypeGet.closure_own_or_parent(c, key, &call_getter/2)

  defp get_from_prototype({:bound, _, _, _, _} = b, key),
    do: FunctionPrototypeGet.fallback(Function.proto_property(b, key), b, key)

  defp get_from_prototype({:builtin, "Error", _}, _key),
    do: :undefined

  defp get_from_prototype({:builtin, name, callback} = fun, key)
       when is_binary(name) and is_function(callback),
       do: FunctionPrototypeGet.fallback(:undefined, fun, key)

  defp get_from_prototype({:builtin, name, props}, key) when is_binary(name) and is_map(props),
    do: get_own(Heap.get_object_prototype(), key)

  defp get_from_prototype(_, _), do: :undefined

  defp primitive_or_class_proto(default_value, key, class_name, receiver),
    do: PrimitiveExoticGet.prototype_property(default_value, key, class_name, receiver)

  def prototype_property_with_receiver(target, key, receiver) do
    case prototype_property_lookup_with_receiver(target, key, receiver) do
      {:found, value} -> value
      :not_found -> :undefined
    end
  end

  defp prototype_property_lookup_with_receiver(nil, _key, _receiver), do: :not_found

  defp prototype_property_lookup_with_receiver({:obj, ref} = target, key, receiver) do
    raw = Heap.get_obj_raw(ref)

    case raw do
      %{proxy_target() => _, proxy_handler() => _} ->
        {:found, get(target, key, receiver)}

      _ ->
        case descriptor_property_with_receiver(target, key, receiver) do
          {:found_from_accessor, value} ->
            {:found, value}

          _ ->
            case raw_own_property(raw, key) do
              {:ok, {:accessor, getter, _}} when getter != nil ->
                {:found, call_getter(getter, receiver)}

              {:ok, {:accessor, nil, _}} ->
                {:found, :undefined}

              {:ok, value} ->
                {:found, value}

              :error ->
                case descriptor_property_with_receiver(target, key, receiver) do
                  :not_found ->
                    prototype_property_lookup_with_receiver(Prototype.get(target), key, receiver)

                  {:found_from_accessor, value} ->
                    {:found, value}

                  found ->
                    found
                end
            end
        end
    end
  end

  defp prototype_property_lookup_with_receiver(target, key, receiver) do
    case descriptor_property_with_receiver(target, key, receiver) do
      :not_found -> prototype_property_lookup_with_receiver(Prototype.get(target), key, receiver)
      found -> found
    end
  end

  defp descriptor_property_with_receiver(target, key, receiver) do
    case OwnProperty.descriptor(target, key) do
      {:obj, _} = desc ->
        getter = get(desc, "get")

        cond do
          not Value.nullish?(getter) ->
            {:found_from_accessor, call_getter(getter, receiver)}

          get(desc, "value") != :undefined ->
            {:found, get(desc, "value")}

          true ->
            {:found, :undefined}
        end

      :undefined ->
        :not_found

      _ ->
        :not_found
    end
  end

  defp raw_own_property(raw, key) when is_map(raw), do: Map.fetch(raw, key)

  defp raw_own_property(raw, key) do
    if Heap.shape?(raw), do: Heap.raw_fetch(raw, key), else: :error
  end

  defp arguments_proto_property(obj, {:symbol, "Symbol.iterator"}) do
    case array_proto_property(obj, {:symbol, "Symbol.iterator"}) do
      :undefined -> get_default_object_prototype(obj, {:symbol, "Symbol.iterator"})
      val -> val
    end
  end

  defp arguments_proto_property(obj, key), do: get_default_object_prototype(obj, key)

  defp array_proto_property({:obj, _} = obj, key), do: ArrayExoticGet.proto_property(obj, key)

  defp array_proto_property(key), do: ArrayExoticGet.proto_property(key)

  defp get_default_object_prototype(obj, key) do
    proto = Heap.get_object_prototype() || Object.build_prototype()

    case proto do
      {:obj, _} = proto when proto != obj -> get(proto, key)
      _ -> :undefined
    end
  end

  def fallback_to_object_proto(:undefined, fun, key), do: get_default_object_prototype(fun, key)
  def fallback_to_object_proto(val, _fun, _key), do: val
end
